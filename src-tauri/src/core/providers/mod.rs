//! AI provider layer (spec-05): named provider profiles talking to any
//! OpenAI-compatible Chat Completions endpoint (see [`openai`]), prompt
//! assembly for the bundled actions, a privacy classification of the
//! endpoint host, and the [`run_action`] orchestration the `run_action`
//! command wraps thinly.
//!
//! [`run_action`] deliberately takes an already-resolved `Option<&
//! ProviderProfile>` rather than `&Settings`: `Settings` (in
//! `core::settings`) holds `Vec<ProviderProfile>` and so already depends on
//! this module, and threading `Settings` back into `run_action` would make
//! the *orchestration* logic depend on the settings shape too, for no
//! benefit — the command layer already has both and can resolve the active
//! profile itself via [`active_profile`] before calling in.

pub mod openai;

#[cfg(test)]
pub mod fakes;

use serde::{Deserialize, Serialize};

use crate::core::secrets::SecretStore;
use crate::core::settings::{SettingsError, SettingsStore};

fn default_timeout_secs() -> u64 {
    30
}

fn default_true() -> bool {
    true
}

/// A single custom HTTP header sent with every request for a profile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeaderEntry {
    pub name: String,
    pub value: String,
}

/// A named connection to an OpenAI-compatible endpoint. The API key itself
/// never lives here — see `has_api_key` — it is looked up separately
/// through [`crate::core::secrets::SecretStore`], keyed by `id`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderProfile {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub model: String,
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    #[serde(default)]
    pub custom_headers: Vec<HeaderEntry>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// Marker only — the key itself lives in the macOS Keychain, never here.
    #[serde(default)]
    pub has_api_key: bool,
}

/// A bundled AI action, or a free-form custom instruction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Action {
    Rewrite,
    Shorten,
    ImproveClarity,
    Custom { instruction: String },
}

/// The strict error taxonomy surfaced by a [`Provider`]. Every variant's
/// `Display` text is the distinct, actionable message shown inline in the
/// popover — never a generic "failed".
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum ProviderError {
    #[error("Can't reach the endpoint — is the server running? ({0})")]
    Unreachable(String),
    #[error("The request timed out after {0} s — the endpoint may be slow or overloaded.")]
    Timeout(u64),
    #[error("The server answered HTTP {status}: {snippet}")]
    Http { status: u16, snippet: String },
    #[error("No model is configured for this profile — set one in Settings.")]
    MissingModel,
    #[error("The base URL is invalid: {0}")]
    InvalidBaseUrl(String),
    #[error("The server sent an unexpected response: {0}")]
    InvalidResponse(String),
}

impl ProviderError {
    /// Stable machine-readable discriminant, sent to the frontend alongside
    /// the human-readable `Display` message.
    pub fn kind(&self) -> &'static str {
        match self {
            ProviderError::Unreachable(_) => "unreachable",
            ProviderError::Timeout(_) => "timeout",
            ProviderError::Http { .. } => "http",
            ProviderError::MissingModel => "missingModel",
            ProviderError::InvalidBaseUrl(_) => "invalidBaseUrl",
            ProviderError::InvalidResponse(_) => "invalidResponse",
        }
    }
}

/// Platform-agnostic seam for talking to an AI provider. The one production
/// implementation is [`openai::OpenAiCompatibleAdapter`]; tests use
/// [`fakes::FakeProvider`].
pub trait Provider {
    fn complete(
        &self,
        profile: &ProviderProfile,
        api_key: Option<&str>,
        system_prompt: &str,
        user_text: &str,
    ) -> impl std::future::Future<Output = Result<String, ProviderError>> + Send;
}

/// The strict instruction every prompt ends with: models love to add
/// preamble ("Here's the rewritten text:") or wrap the result in quotes,
/// both of which would land verbatim in the source app on replace-back.
const RETURN_ONLY_TEXT_INSTRUCTION: &str = "Return only the transformed text, with no preamble, commentary, or surrounding quotes. Preserve the text's original language.";

/// Builds the system prompt for `action`. The user's text is always sent
/// verbatim as the user message — never folded into this prompt — so it
/// can't be reinterpreted as instructions.
pub fn assemble_prompt(action: &Action) -> String {
    match action {
        Action::Rewrite => format!(
            "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone. {RETURN_ONLY_TEXT_INSTRUCTION}"
        ),
        Action::Shorten => format!(
            "Make the user's text noticeably shorter while keeping its essential meaning and tone. {RETURN_ONLY_TEXT_INSTRUCTION}"
        ),
        Action::ImproveClarity => format!(
            "Make the user's text clearer and easier to understand without changing its meaning. {RETURN_ONLY_TEXT_INSTRUCTION}"
        ),
        Action::Custom { instruction } => format!(
            "Apply the following instruction to the user's text: {instruction} {RETURN_ONLY_TEXT_INSTRUCTION}"
        ),
    }
}

/// A coarse privacy classification of a provider endpoint's host, derived
/// from the URL alone — DNS is never resolved.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PrivacyClass {
    Local,
    Lan,
    Cloud,
}

fn classify_ipv4(ip: std::net::Ipv4Addr) -> PrivacyClass {
    if ip.is_loopback() {
        PrivacyClass::Local
    } else if ip.is_private() || ip.is_link_local() {
        PrivacyClass::Lan
    } else {
        PrivacyClass::Cloud
    }
}

/// `fc00::/7` (unique local addresses).
fn ipv6_is_unique_local(ip: &std::net::Ipv6Addr) -> bool {
    (ip.segments()[0] & 0xfe00) == 0xfc00
}

/// `fe80::/10` (link-local addresses).
fn ipv6_is_link_local(ip: &std::net::Ipv6Addr) -> bool {
    (ip.segments()[0] & 0xffc0) == 0xfe80
}

fn classify_ipv6(ip: std::net::Ipv6Addr) -> PrivacyClass {
    if ip.is_loopback() {
        PrivacyClass::Local
    } else if ipv6_is_unique_local(&ip) || ipv6_is_link_local(&ip) {
        PrivacyClass::Lan
    } else {
        PrivacyClass::Cloud
    }
}

fn classify_domain(domain: &str) -> PrivacyClass {
    let lower = domain.to_ascii_lowercase();
    let lower = lower.trim_end_matches('.');
    if lower == "localhost" || lower.ends_with(".localhost") {
        return PrivacyClass::Local;
    }
    if lower.ends_with(".local")
        || lower.ends_with(".lan")
        || lower.ends_with(".home")
        || lower.ends_with(".internal")
    {
        return PrivacyClass::Lan;
    }
    if !lower.is_empty() && !lower.contains('.') {
        // Single-label hostnames are LAN DNS/mDNS names ("aiserver"), never
        // publicly routable.
        return PrivacyClass::Lan;
    }
    PrivacyClass::Cloud
}

/// Classifies `base_url`'s host. Returns `None` when the URL (or its host)
/// can't be parsed at all — callers should treat that the same as "unknown"
/// (the request itself will surface `InvalidBaseUrl` at call time).
pub fn classify_privacy(base_url: &str) -> Option<PrivacyClass> {
    let url = url::Url::parse(base_url).ok()?;
    match url.host()? {
        url::Host::Ipv4(v4) => Some(classify_ipv4(v4)),
        url::Host::Ipv6(v6) => Some(classify_ipv6(v6)),
        url::Host::Domain(domain) => Some(classify_domain(domain)),
    }
}

/// Outcome of a single [`run_action`] call, sent to the frontend as-is.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum RunActionOutcome {
    Ok {
        text: String,
    },
    NotConfigured,
    /// Produced by the command layer on cancel, never by [`run_action`]
    /// itself (which has no notion of cancellation).
    Cancelled,
    Error {
        kind: String,
        message: String,
    },
}

/// Returns the profile in `profiles` whose id matches `active_id` — but
/// only if it is also `enabled`. A disabled profile is treated exactly like
/// no active profile at all.
pub fn active_profile<'a>(
    profiles: &'a [ProviderProfile],
    active_id: Option<&str>,
) -> Option<&'a ProviderProfile> {
    let active_id = active_id?;
    profiles.iter().find(|p| p.id == active_id && p.enabled)
}

/// Runs a single AI action against the already-resolved `active` profile.
/// Never calls `provider` when `active` is `None` (surfaces
/// [`RunActionOutcome::NotConfigured`] instead). The API key is only read
/// from `secrets` when `profile.has_api_key` is set; a `secrets` read
/// failure degrades to "no key" rather than failing the action outright —
/// a locally-hosted model may not need a key at all, and a Keychain hiccup
/// shouldn't block a request that might succeed without one.
pub async fn run_action<P: Provider>(
    active: Option<&ProviderProfile>,
    secrets: &dyn SecretStore,
    provider: &P,
    text: &str,
    action: &Action,
) -> RunActionOutcome {
    let Some(profile) = active else {
        return RunActionOutcome::NotConfigured;
    };

    let api_key = if profile.has_api_key {
        secrets.get(&profile.id).ok().flatten()
    } else {
        None
    };

    let system_prompt = assemble_prompt(action);

    match provider
        .complete(profile, api_key.as_deref(), &system_prompt, text)
        .await
    {
        Ok(result_text) => RunActionOutcome::Ok { text: result_text },
        Err(e) => RunActionOutcome::Error {
            kind: e.kind().to_string(),
            message: e.to_string(),
        },
    }
}

/// Validates a profile before it is saved. `base_url` and `model` are
/// intentionally *not* validated here — an empty or malformed value there
/// still saves, and instead fails at request time with the more specific
/// `InvalidBaseUrl`/`MissingModel` provider errors, so misconfiguration
/// surfaces through the same error taxonomy the user sees for every other
/// request failure.
pub fn validate_profile(profile: &ProviderProfile) -> Result<(), String> {
    if profile.name.trim().is_empty() {
        return Err("Profile name must not be empty.".to_string());
    }
    if profile.timeout_secs < 1 {
        return Err("Timeout must be at least 1 second.".to_string());
    }
    Ok(())
}

/// A bundled preset offered when creating a new profile.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preset {
    pub id: &'static str,
    pub label: &'static str,
    pub base_url: &'static str,
    pub needs_api_key: bool,
}

pub fn presets() -> Vec<Preset> {
    vec![
        Preset {
            id: "ollama",
            label: "Ollama",
            base_url: "http://localhost:11434/v1",
            needs_api_key: false,
        },
        Preset {
            id: "lmstudio",
            label: "LM Studio",
            base_url: "http://localhost:1234/v1",
            needs_api_key: false,
        },
        Preset {
            id: "openai",
            label: "OpenAI",
            base_url: "https://api.openai.com/v1",
            needs_api_key: true,
        },
        Preset {
            id: "custom",
            label: "Custom (OpenAI-compatible)",
            base_url: "",
            needs_api_key: false,
        },
    ]
}

/// Summary of the active profile, for the popover to show "which endpoint,
/// which privacy class" without exposing the full profile list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionContext {
    pub configured: bool,
    pub profile_name: Option<String>,
    pub privacy: Option<PrivacyClass>,
}

/// Builds an [`ActionContext`] for the currently active, enabled profile
/// (if any). An unparseable `base_url` leaves `privacy` as `None` while
/// `configured` stays `true` — the run itself will surface `InvalidBaseUrl`.
pub fn action_context(profiles: &[ProviderProfile], active_id: Option<&str>) -> ActionContext {
    match active_profile(profiles, active_id) {
        Some(profile) => ActionContext {
            configured: true,
            profile_name: Some(profile.name.clone()),
            privacy: classify_privacy(&profile.base_url),
        },
        None => ActionContext {
            configured: false,
            profile_name: None,
            privacy: None,
        },
    }
}

/// Errors from the profile CRUD "core" functions below, which compose
/// [`SettingsStore`] and [`SecretStore`].
#[derive(Debug, thiserror::Error)]
pub enum ProfileOpError {
    #[error("{0}")]
    Validation(String),
    #[error(transparent)]
    Settings(#[from] SettingsError),
    #[error(transparent)]
    Secrets(#[from] crate::core::secrets::SecretsError),
    #[error("no profile with id \"{0}\"")]
    NotFound(String),
}

fn upsert_by_id(profiles: &mut Vec<ProviderProfile>, profile: ProviderProfile) {
    if let Some(existing) = profiles.iter_mut().find(|p| p.id == profile.id) {
        *existing = profile;
    } else {
        profiles.push(profile);
    }
}

/// Creates or updates a profile, and applies `api_key`'s effect on the
/// Keychain entry: `None` leaves the existing key (and `has_api_key`)
/// untouched (`false` for a brand-new profile); `Some(s)` where `s` is
/// blank after trimming deletes the key and clears `has_api_key`;
/// `Some(s)` otherwise sets the key and `has_api_key`. Generates a fresh id
/// when `profile.id` is empty. If this is the very first profile and no
/// profile is currently active, it becomes the active profile. Returns the
/// updated profile list; the settings JSON this saves never contains the
/// key itself.
pub fn save_profile_core(
    settings_store: &dyn SettingsStore,
    secrets: &dyn SecretStore,
    mut profile: ProviderProfile,
    api_key: Option<String>,
) -> Result<Vec<ProviderProfile>, ProfileOpError> {
    validate_profile(&profile).map_err(ProfileOpError::Validation)?;

    let mut settings = settings_store.load()?;

    if profile.id.trim().is_empty() {
        profile.id = uuid::Uuid::new_v4().to_string();
    }

    let existing_has_key = settings
        .profiles
        .iter()
        .find(|p| p.id == profile.id)
        .map(|p| p.has_api_key);

    match api_key {
        None => {
            profile.has_api_key = existing_has_key.unwrap_or(false);
        }
        Some(key) if key.trim().is_empty() => {
            secrets.delete(&profile.id)?;
            profile.has_api_key = false;
        }
        Some(key) => {
            secrets.set(&profile.id, &key)?;
            profile.has_api_key = true;
        }
    }

    let was_empty = settings.profiles.is_empty();
    let new_id = profile.id.clone();
    upsert_by_id(&mut settings.profiles, profile);

    if was_empty && settings.active_profile_id.is_none() {
        settings.active_profile_id = Some(new_id);
    }

    settings_store.save(&settings)?;
    Ok(settings.profiles)
}

/// Removes the profile with `id`, deletes its Keychain entry (a missing
/// entry is not an error), and clears `active_profile_id` if it pointed at
/// the removed profile.
pub fn delete_profile_core(
    settings_store: &dyn SettingsStore,
    secrets: &dyn SecretStore,
    id: &str,
) -> Result<Vec<ProviderProfile>, ProfileOpError> {
    let mut settings = settings_store.load()?;
    settings.profiles.retain(|p| p.id != id);
    secrets.delete(id)?;
    if settings.active_profile_id.as_deref() == Some(id) {
        settings.active_profile_id = None;
    }
    settings_store.save(&settings)?;
    Ok(settings.profiles)
}

/// Sets the active profile id. `Some(id)` must reference an existing
/// profile (otherwise `NotFound`); `None` clears the active profile.
pub fn set_active_profile_core(
    settings_store: &dyn SettingsStore,
    id: Option<String>,
) -> Result<(), ProfileOpError> {
    let mut settings = settings_store.load()?;
    if let Some(ref id) = id {
        if !settings.profiles.iter().any(|p| &p.id == id) {
            return Err(ProfileOpError::NotFound(id.clone()));
        }
    }
    settings.active_profile_id = id;
    settings_store.save(&settings)?;
    Ok(())
}

/// Convenience used by the `list_profiles` command.
pub fn list_profiles_core(
    settings_store: &dyn SettingsStore,
) -> Result<Vec<ProviderProfile>, SettingsError> {
    Ok(settings_store.load()?.profiles)
}

#[cfg(test)]
mod tests {
    use super::fakes::FakeProvider;
    use super::*;
    use crate::core::secrets::fakes::InMemorySecretStore;
    use crate::core::settings::InMemorySettingsStore;

    fn sample_profile(id: &str) -> ProviderProfile {
        ProviderProfile {
            id: id.to_string(),
            name: format!("Profile {id}"),
            base_url: "http://localhost:11434/v1".to_string(),
            model: "llama3".to_string(),
            timeout_secs: 30,
            custom_headers: vec![],
            enabled: true,
            has_api_key: false,
        }
    }

    // ---- assemble_prompt ----------------------------------------------

    #[test]
    fn every_bundled_action_prompt_demands_only_the_transformed_text() {
        for action in [Action::Rewrite, Action::Shorten, Action::ImproveClarity] {
            let prompt = assemble_prompt(&action);
            assert!(prompt.contains("Return only the transformed text"));
            assert!(prompt.contains("Preserve the text's original language"));
        }
    }

    #[test]
    fn custom_action_embeds_the_instruction_verbatim() {
        let action = Action::Custom {
            instruction: "Translate to French".to_string(),
        };
        let prompt = assemble_prompt(&action);
        assert!(prompt.contains("Translate to French"));
        assert!(prompt.contains("Return only the transformed text"));
    }

    // ---- classify_privacy ----------------------------------------------

    #[test]
    fn localhost_variants_classify_as_local() {
        for url in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:1234/v1",
            "http://127.5.5.5/v1",
            "http://[::1]:8080/v1",
            "http://foo.localhost/v1",
        ] {
            assert_eq!(classify_privacy(url), Some(PrivacyClass::Local), "{url}");
        }
    }

    #[test]
    fn private_and_link_local_addresses_classify_as_lan() {
        for url in [
            "http://10.0.0.5/v1",
            "http://172.16.0.5/v1",
            "http://172.31.255.255/v1",
            "http://192.168.1.10:8080/v1",
            "http://169.254.1.1/v1",
            "http://[fc00::1]/v1",
            "http://[fe80::1]/v1",
            "http://foo.local/v1",
            "http://foo.lan/v1",
            "http://foo.home/v1",
            "http://foo.internal/v1",
            "http://aiserver/v1",
            "http://aiserver:8080/v1",
        ] {
            assert_eq!(classify_privacy(url), Some(PrivacyClass::Lan), "{url}");
        }
    }

    #[test]
    fn public_hosts_classify_as_cloud() {
        for url in [
            "https://api.openai.com/v1",
            "http://8.8.8.8/v1",
            "https://example.com/v1",
        ] {
            assert_eq!(classify_privacy(url), Some(PrivacyClass::Cloud), "{url}");
        }
    }

    #[test]
    fn garbage_or_empty_urls_classify_as_unknown() {
        assert_eq!(classify_privacy(""), None);
        assert_eq!(classify_privacy("not a url"), None);
    }

    // ---- validate_profile / active_profile ------------------------------

    #[test]
    fn blank_name_fails_validation() {
        let mut profile = sample_profile("a");
        profile.name = "   ".to_string();
        assert!(validate_profile(&profile).is_err());
    }

    #[test]
    fn zero_timeout_fails_validation() {
        let mut profile = sample_profile("a");
        profile.timeout_secs = 0;
        assert!(validate_profile(&profile).is_err());
    }

    #[test]
    fn empty_base_url_and_model_pass_validation() {
        let mut profile = sample_profile("a");
        profile.base_url = "".to_string();
        profile.model = "".to_string();
        assert!(validate_profile(&profile).is_ok());
    }

    #[test]
    fn active_profile_requires_matching_id_and_enabled() {
        let enabled = sample_profile("a");
        let mut disabled = sample_profile("b");
        disabled.enabled = false;
        let profiles = vec![enabled.clone(), disabled.clone()];

        assert_eq!(active_profile(&profiles, Some("a")), Some(&enabled));
        assert_eq!(active_profile(&profiles, Some("b")), None);
        assert_eq!(active_profile(&profiles, Some("missing")), None);
        assert_eq!(active_profile(&profiles, None), None);
    }

    // ---- action_context --------------------------------------------------

    #[test]
    fn action_context_reports_not_configured_without_an_active_profile() {
        let ctx = action_context(&[], None);
        assert_eq!(
            ctx,
            ActionContext {
                configured: false,
                profile_name: None,
                privacy: None
            }
        );
    }

    #[test]
    fn action_context_reports_the_active_profiles_name_and_privacy() {
        let profile = sample_profile("a");
        let ctx = action_context(&[profile.clone()], Some("a"));
        assert_eq!(ctx.configured, true);
        assert_eq!(ctx.profile_name, Some(profile.name));
        assert_eq!(ctx.privacy, Some(PrivacyClass::Local));
    }

    #[test]
    fn action_context_leaves_privacy_none_for_an_unparseable_url_but_stays_configured() {
        let mut profile = sample_profile("a");
        profile.base_url = "not a url".to_string();
        let ctx = action_context(&[profile], Some("a"));
        assert!(ctx.configured);
        assert_eq!(ctx.privacy, None);
    }

    // ---- run_action orchestration ---------------------------------------

    #[tokio::test]
    async fn no_active_profile_is_not_configured_and_never_calls_the_provider() {
        let secrets = InMemorySecretStore::new();
        let provider = FakeProvider::returning("result");

        let outcome = run_action(None, &secrets, &provider, "hello", &Action::Rewrite).await;

        assert_eq!(outcome, RunActionOutcome::NotConfigured);
        assert!(provider.calls().is_empty());
    }

    #[tokio::test]
    async fn disabled_active_profile_resolves_to_none_and_is_not_configured() {
        // Mirrors what the command layer does: `active_profile` already
        // filters out disabled profiles before `run_action` ever sees them.
        let mut profile = sample_profile("a");
        profile.enabled = false;
        let profiles = vec![profile];
        let secrets = InMemorySecretStore::new();
        let provider = FakeProvider::returning("result");

        let active = active_profile(&profiles, Some("a"));
        let outcome = run_action(active, &secrets, &provider, "hello", &Action::Rewrite).await;

        assert_eq!(outcome, RunActionOutcome::NotConfigured);
        assert!(provider.calls().is_empty());
    }

    #[tokio::test]
    async fn successful_completion_maps_text_through() {
        let profile = sample_profile("a");
        let secrets = InMemorySecretStore::new();
        let provider = FakeProvider::returning("rewritten text");

        let outcome = run_action(
            Some(&profile),
            &secrets,
            &provider,
            "hello",
            &Action::Rewrite,
        )
        .await;

        assert_eq!(
            outcome,
            RunActionOutcome::Ok {
                text: "rewritten text".to_string()
            }
        );
        let calls = provider.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].user_text, "hello");
        assert_eq!(calls[0].api_key, None);
    }

    #[tokio::test]
    async fn each_provider_error_variant_maps_to_the_matching_kind() {
        let profile = sample_profile("a");
        let secrets = InMemorySecretStore::new();

        let cases: Vec<(ProviderError, &str)> = vec![
            (ProviderError::Unreachable("x".to_string()), "unreachable"),
            (ProviderError::Timeout(30), "timeout"),
            (
                ProviderError::Http {
                    status: 500,
                    snippet: "boom".to_string(),
                },
                "http",
            ),
            (ProviderError::MissingModel, "missingModel"),
            (
                ProviderError::InvalidBaseUrl("bad".to_string()),
                "invalidBaseUrl",
            ),
            (
                ProviderError::InvalidResponse("weird".to_string()),
                "invalidResponse",
            ),
        ];

        for (err, expected_kind) in cases {
            let message = err.to_string();
            let provider = FakeProvider::failing(err);
            let outcome = run_action(
                Some(&profile),
                &secrets,
                &provider,
                "hello",
                &Action::Rewrite,
            )
            .await;
            assert_eq!(
                outcome,
                RunActionOutcome::Error {
                    kind: expected_kind.to_string(),
                    message,
                }
            );
        }
    }

    #[tokio::test]
    async fn api_key_is_fetched_from_secrets_when_the_profile_has_one() {
        let mut profile = sample_profile("a");
        profile.has_api_key = true;
        let secrets = InMemorySecretStore::new();
        secrets.set("a", "sk-secret").unwrap();
        let provider = FakeProvider::returning("ok");

        run_action(
            Some(&profile),
            &secrets,
            &provider,
            "hello",
            &Action::Rewrite,
        )
        .await;

        let calls = provider.calls();
        assert_eq!(calls[0].api_key, Some("sk-secret".to_string()));
    }

    #[tokio::test]
    async fn secrets_backend_error_degrades_to_no_key_and_still_calls_the_provider() {
        let mut profile = sample_profile("a");
        profile.has_api_key = true;
        let secrets = InMemorySecretStore::new();
        secrets.fail_next_get();
        let provider = FakeProvider::returning("ok");

        let outcome = run_action(
            Some(&profile),
            &secrets,
            &provider,
            "hello",
            &Action::Rewrite,
        )
        .await;

        assert_eq!(
            outcome,
            RunActionOutcome::Ok {
                text: "ok".to_string()
            }
        );
        let calls = provider.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].api_key, None);
    }

    // ---- profile CRUD core fns -------------------------------------------

    #[test]
    fn saving_a_profile_with_an_empty_id_generates_one() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        let mut profile = sample_profile("");
        profile.id = "".to_string();

        let profiles = save_profile_core(&settings_store, &secrets, profile, None).unwrap();

        assert_eq!(profiles.len(), 1);
        assert!(!profiles[0].id.is_empty());
    }

    #[test]
    fn saving_an_existing_id_upserts_in_place() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(&settings_store, &secrets, sample_profile("a"), None).unwrap();

        let mut updated = sample_profile("a");
        updated.name = "Renamed".to_string();
        let profiles = save_profile_core(&settings_store, &secrets, updated, None).unwrap();

        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "Renamed");
    }

    #[test]
    fn the_first_saved_profile_becomes_active() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();

        save_profile_core(&settings_store, &secrets, sample_profile("a"), None).unwrap();

        let settings = settings_store.load().unwrap();
        assert_eq!(settings.active_profile_id, Some("a".to_string()));
    }

    #[test]
    fn a_second_saved_profile_does_not_change_the_active_profile() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(&settings_store, &secrets, sample_profile("a"), None).unwrap();

        save_profile_core(&settings_store, &secrets, sample_profile("b"), None).unwrap();

        let settings = settings_store.load().unwrap();
        assert_eq!(settings.active_profile_id, Some("a".to_string()));
    }

    #[test]
    fn api_key_none_preserves_existing_has_api_key() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        let mut profile = sample_profile("a");
        profile.has_api_key = false;
        save_profile_core(
            &settings_store,
            &secrets,
            profile.clone(),
            Some("sk-key".to_string()),
        )
        .unwrap();

        // Save again without touching the key.
        let profiles = save_profile_core(&settings_store, &secrets, profile, None).unwrap();

        assert!(profiles[0].has_api_key);
        assert_eq!(secrets.get("a").unwrap(), Some("sk-key".to_string()));
    }

    #[test]
    fn api_key_some_empty_clears_the_key_and_flag() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(
            &settings_store,
            &secrets,
            sample_profile("a"),
            Some("sk-key".to_string()),
        )
        .unwrap();

        let profiles = save_profile_core(
            &settings_store,
            &secrets,
            sample_profile("a"),
            Some("   ".to_string()),
        )
        .unwrap();

        assert!(!profiles[0].has_api_key);
        assert_eq!(secrets.get("a").unwrap(), None);
    }

    #[test]
    fn api_key_some_sets_the_key_and_flag() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();

        let profiles = save_profile_core(
            &settings_store,
            &secrets,
            sample_profile("a"),
            Some("sk-key".to_string()),
        )
        .unwrap();

        assert!(profiles[0].has_api_key);
        assert_eq!(secrets.get("a").unwrap(), Some("sk-key".to_string()));
    }

    #[test]
    fn secrets_never_appear_in_the_persisted_settings_json() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(
            &settings_store,
            &secrets,
            sample_profile("a"),
            Some("sk-super-secret".to_string()),
        )
        .unwrap();

        let settings = settings_store.load().unwrap();
        let json = serde_json::to_string(&settings).unwrap();

        assert!(!json.contains("sk-super-secret"));
    }

    #[test]
    fn deleting_a_profile_removes_it_and_its_key_and_clears_active_id() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(
            &settings_store,
            &secrets,
            sample_profile("a"),
            Some("sk-key".to_string()),
        )
        .unwrap();

        let profiles = delete_profile_core(&settings_store, &secrets, "a").unwrap();

        assert!(profiles.is_empty());
        assert_eq!(secrets.get("a").unwrap(), None);
        assert_eq!(settings_store.load().unwrap().active_profile_id, None);
    }

    #[test]
    fn set_active_profile_rejects_an_unknown_id() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(&settings_store, &secrets, sample_profile("a"), None).unwrap();

        let result = set_active_profile_core(&settings_store, Some("missing".to_string()));

        assert!(matches!(result, Err(ProfileOpError::NotFound(id)) if id == "missing"));
    }

    #[test]
    fn set_active_profile_round_trips_a_known_id() {
        let settings_store = InMemorySettingsStore::new();
        let secrets = InMemorySecretStore::new();
        save_profile_core(&settings_store, &secrets, sample_profile("a"), None).unwrap();
        save_profile_core(&settings_store, &secrets, sample_profile("b"), None).unwrap();

        set_active_profile_core(&settings_store, Some("b".to_string())).unwrap();

        assert_eq!(
            settings_store.load().unwrap().active_profile_id,
            Some("b".to_string())
        );
    }
}
