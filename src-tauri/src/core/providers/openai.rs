//! The one generic [`Provider`] adapter: talks to any OpenAI-compatible
//! Chat Completions endpoint over HTTP.

use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{json, Value};

use super::{Provider, ProviderError, ProviderProfile};

/// Talks to any server implementing the OpenAI Chat Completions API shape
/// (`POST {base_url}/chat/completions`) — the one adapter for every
/// provider profile, local or cloud.
pub struct OpenAiCompatibleAdapter;

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    #[serde(default)]
    choices: Vec<Choice>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: ChoiceMessage,
}

#[derive(Debug, Deserialize)]
struct ChoiceMessage {
    content: Option<String>,
}

/// Builds `{base_url}/chat/completions`, trimming trailing slashes from
/// `base_url` first. Validates that `base_url` parses as a URL with an
/// `http`/`https` scheme; anything else is `InvalidBaseUrl`.
fn endpoint(base_url: &str) -> Result<String, ProviderError> {
    let url =
        url::Url::parse(base_url).map_err(|e| ProviderError::InvalidBaseUrl(e.to_string()))?;
    match url.scheme() {
        "http" | "https" => {}
        other => {
            return Err(ProviderError::InvalidBaseUrl(format!(
                "unsupported scheme \"{other}\" (must be http or https)"
            )))
        }
    }
    let trimmed = base_url.trim_end_matches('/');
    Ok(format!("{trimmed}/chat/completions"))
}

/// Builds the POST request for `body` against `profile`: validates
/// `base_url` and `model` (before any request is sent), sets the
/// per-request timeout, and attaches the `Authorization` header (when an
/// API key is given) followed by the profile's custom headers. Entries
/// whose name or value don't form a valid HTTP header are silently
/// skipped — they are user-supplied data, not a protocol error worth
/// failing the whole request over.
fn build_request(
    client: &reqwest::Client,
    profile: &ProviderProfile,
    api_key: Option<&str>,
    body: &Value,
) -> Result<reqwest::RequestBuilder, ProviderError> {
    let url = endpoint(&profile.base_url)?;
    if profile.model.trim().is_empty() {
        return Err(ProviderError::MissingModel);
    }

    let mut request = client
        .post(&url)
        .timeout(Duration::from_secs(profile.timeout_secs))
        .json(body);

    if let Some(key) = api_key {
        request = request.header(reqwest::header::AUTHORIZATION, format!("Bearer {key}"));
    }

    for header in &profile.custom_headers {
        if header.name.trim().is_empty() {
            continue;
        }
        if let (Ok(name), Ok(value)) = (
            reqwest::header::HeaderName::from_bytes(header.name.as_bytes()),
            reqwest::header::HeaderValue::from_str(&header.value),
        ) {
            request = request.header(name, value);
        }
    }

    Ok(request)
}

fn map_send_error(e: reqwest::Error, timeout_secs: u64) -> ProviderError {
    if e.is_timeout() {
        ProviderError::Timeout(timeout_secs)
    } else {
        ProviderError::Unreachable(e.to_string())
    }
}

/// Truncates `s` to at most `max_chars` Unicode scalar values (always on a
/// char boundary).
fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        s.to_string()
    } else {
        s.chars().take(max_chars).collect()
    }
}

/// Sends `request`, maps transport failures, non-2xx responses, and
/// malformed response bodies to the [`ProviderError`] taxonomy, and
/// extracts `choices[0].message.content` (trimmed) on success.
async fn send_and_extract_content(
    request: reqwest::RequestBuilder,
    timeout_secs: u64,
) -> Result<String, ProviderError> {
    let response = request
        .send()
        .await
        .map_err(|e| map_send_error(e, timeout_secs))?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(ProviderError::Http {
            status: status.as_u16(),
            snippet: truncate(&body, 300),
        });
    }

    let body = response.text().await.map_err(|e| {
        ProviderError::InvalidResponse(format!("failed to read response body: {e}"))
    })?;

    let parsed: ChatCompletionResponse = serde_json::from_str(&body)
        .map_err(|e| ProviderError::InvalidResponse(format!("invalid JSON: {e}")))?;

    let content = parsed
        .choices
        .into_iter()
        .next()
        .ok_or_else(|| ProviderError::InvalidResponse("response contained no choices".to_string()))?
        .message
        .content
        .ok_or_else(|| {
            ProviderError::InvalidResponse("message content was missing or null".to_string())
        })?;

    Ok(content.trim().to_string())
}

impl Provider for OpenAiCompatibleAdapter {
    fn complete(
        &self,
        profile: &ProviderProfile,
        api_key: Option<&str>,
        system_prompt: &str,
        user_text: &str,
    ) -> impl std::future::Future<Output = Result<String, ProviderError>> + Send {
        async move {
            let body = json!({
                "model": profile.model,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_text},
                ],
                "stream": false,
            });
            let client = reqwest::Client::new();
            let request = build_request(&client, profile, api_key, &body)?;
            send_and_extract_content(request, profile.timeout_secs).await
        }
    }
}

/// Sends a minimal chat completion through the same request/error-mapping
/// path as [`Provider::complete`] and returns the round-trip latency in
/// milliseconds on success.
pub async fn test_connection(
    profile: &ProviderProfile,
    api_key: Option<&str>,
) -> Result<u128, ProviderError> {
    let body = json!({
        "model": profile.model,
        "messages": [
            {"role": "user", "content": "Say OK"},
        ],
        "stream": false,
        "max_tokens": 8,
    });
    let client = reqwest::Client::new();
    let request = build_request(&client, profile, api_key, &body)?;
    let start = Instant::now();
    send_and_extract_content(request, profile.timeout_secs).await?;
    Ok(start.elapsed().as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::providers::HeaderEntry;
    use serde_json::Value as JsonValue;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn profile_for(base_url: String) -> ProviderProfile {
        ProviderProfile {
            id: "p1".to_string(),
            name: "Test".to_string(),
            base_url,
            model: "test-model".to_string(),
            timeout_secs: 30,
            custom_headers: vec![],
            enabled: true,
            has_api_key: false,
        }
    }

    fn success_body(content: &str) -> JsonValue {
        json!({
            "choices": [
                { "message": { "role": "assistant", "content": content } }
            ]
        })
    }

    #[tokio::test]
    async fn success_returns_content_and_sends_the_expected_request() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .and(header("authorization", "Bearer sk-test"))
            .and(header("x-custom", "custom-value"))
            .respond_with(ResponseTemplate::new(200).set_body_json(success_body("  Hello there  ")))
            .expect(1)
            .mount(&server)
            .await;

        let mut profile = profile_for(server.uri());
        profile.custom_headers = vec![HeaderEntry {
            name: "X-Custom".to_string(),
            value: "custom-value".to_string(),
        }];

        let adapter = OpenAiCompatibleAdapter;
        let result = adapter
            .complete(&profile, Some("sk-test"), "system prompt", "user text")
            .await;

        assert_eq!(result, Ok("Hello there".to_string()));

        let requests = server.received_requests().await.unwrap();
        assert_eq!(requests.len(), 1);
        let body: JsonValue = serde_json::from_slice(&requests[0].body).unwrap();
        assert_eq!(body["model"], "test-model");
        assert_eq!(body["stream"], false);
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "system prompt");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["messages"][1]["content"], "user text");
    }

    #[tokio::test]
    async fn connection_refused_is_unreachable() {
        // Bind a listener to reserve a port, then drop it so nothing is
        // listening there.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let profile = profile_for(format!("http://127.0.0.1:{port}"));
        let adapter = OpenAiCompatibleAdapter;
        let result = adapter.complete(&profile, None, "system", "user").await;

        assert!(
            matches!(result, Err(ProviderError::Unreachable(_))),
            "{result:?}"
        );
    }

    #[tokio::test]
    async fn slow_response_past_the_profile_timeout_is_a_timeout_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(success_body("too slow"))
                    .set_delay(Duration::from_secs(3)),
            )
            .mount(&server)
            .await;

        let mut profile = profile_for(server.uri());
        profile.timeout_secs = 1;

        let adapter = OpenAiCompatibleAdapter;
        let result = adapter.complete(&profile, None, "system", "user").await;

        assert!(
            matches!(result, Err(ProviderError::Timeout(1))),
            "{result:?}"
        );
    }

    #[tokio::test]
    async fn non_2xx_status_is_an_http_error_with_a_truncated_snippet() {
        let server = MockServer::start().await;
        let long_body = "x".repeat(500);
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(500).set_body_string(long_body.clone()))
            .mount(&server)
            .await;

        let profile = profile_for(server.uri());
        let adapter = OpenAiCompatibleAdapter;
        let result = adapter.complete(&profile, None, "system", "user").await;

        match result {
            Err(ProviderError::Http { status, snippet }) => {
                assert_eq!(status, 500);
                assert!(snippet.chars().count() <= 300);
                assert!(long_body.starts_with(&snippet));
            }
            other => panic!("expected Http error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn empty_model_is_a_missing_model_error_without_any_request() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(success_body("unused")))
            .expect(0)
            .mount(&server)
            .await;

        let mut profile = profile_for(server.uri());
        profile.model = "   ".to_string();

        let adapter = OpenAiCompatibleAdapter;
        let result = adapter.complete(&profile, None, "system", "user").await;

        assert!(
            matches!(result, Err(ProviderError::MissingModel)),
            "{result:?}"
        );
    }

    #[tokio::test]
    async fn invalid_base_urls_are_rejected_without_any_request() {
        for base_url in ["not a url", "ftp://x"] {
            let profile = profile_for(base_url.to_string());
            let adapter = OpenAiCompatibleAdapter;
            let result = adapter.complete(&profile, None, "system", "user").await;
            assert!(
                matches!(result, Err(ProviderError::InvalidBaseUrl(_))),
                "{base_url}: {result:?}"
            );
        }
    }

    #[tokio::test]
    async fn test_connection_returns_latency_on_success() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(success_body("OK")))
            .mount(&server)
            .await;

        let profile = profile_for(server.uri());
        let result = test_connection(&profile, None).await;

        assert!(result.is_ok(), "{result:?}");
    }

    #[tokio::test]
    async fn test_connection_maps_errors_the_same_way() {
        let mut profile = profile_for("http://localhost:1".to_string());
        profile.model = "".to_string();

        let result = test_connection(&profile, None).await;

        assert!(
            matches!(result, Err(ProviderError::MissingModel)),
            "{result:?}"
        );
    }
}
