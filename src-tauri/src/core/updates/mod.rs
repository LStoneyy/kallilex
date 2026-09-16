//! Update discovery: pure logic that turns "the list of GitHub releases"
//! into "the one release this build should offer, if any" — channel
//! selection, semver comparison against the running build, and the
//! due-for-a-scheduled-check rule. No network call happens outside
//! [`fetch_releases`]. See [`state`] for the machine-local "when did we
//! last check" bookkeeping that lives alongside this module but outside
//! [`crate::core::settings::Settings`], and [`runtime`] for the managed
//! runtime state, commands, and scheduler that call into this module (the
//! plugin that downloads and installs a resolved release is spec-19).

pub mod runtime;
pub mod state;

use std::time::Duration;

use serde::{Deserialize, Serialize};
use url::Url;

/// `owner/repo` path of the GitHub repository releases are resolved
/// against.
const REPO_PATH: &str = "LStoneyy/kallilex";

/// Pinned GitHub REST API version, sent as `X-GitHub-Api-Version` — see
/// <https://docs.github.com/en/rest/about-the-rest-api/api-versions>.
const GITHUB_API_VERSION: &str = "2022-11-28";

/// Per-request timeout for [`fetch_releases`]: generous enough for a slow
/// network, short enough that a manual "check for updates" click never
/// hangs the UI indefinitely.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// The `User-Agent` header GitHub requires on every request.
fn user_agent() -> String {
    format!("Kallilex/{}", env!("CARGO_PKG_VERSION"))
}

/// Which GitHub release channel a build follows. See
/// [`crate::core::settings::Settings::update_channel`] for why the default
/// is build-dependent rather than a fixed value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdateChannel {
    Stable,
    Preview,
}

/// How often Kallilex should look for updates. `Default` is `Daily` — see
/// [`crate::core::settings::Settings::update_check_frequency`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdateCheckFrequency {
    Never,
    OnLaunch,
    #[default]
    Daily,
    Weekly,
}

/// Pure rule behind [`crate::core::settings::Settings::update_channel`]'s
/// build-dependent default: a version carrying a semver pre-release suffix
/// (`0.6.0-beta.1`) follows `Preview`; a version without one follows
/// `Stable`. Deliberately has no opinion on *persisted* settings — a
/// persisted choice always wins, see [`default_update_channel`] and the
/// field's doc comment.
pub fn channel_for_build_version(version: &semver::Version) -> UpdateChannel {
    if version.pre.is_empty() {
        UpdateChannel::Stable
    } else {
        UpdateChannel::Preview
    }
}

/// [`Settings::update_channel`](crate::core::settings::Settings::update_channel)'s
/// `#[serde(default = ...)]` function: [`channel_for_build_version`]
/// evaluated on the running build's own version.
pub fn default_update_channel() -> UpdateChannel {
    let version = semver::Version::parse(env!("CARGO_PKG_VERSION"))
        .expect("CARGO_PKG_VERSION must be a valid semver version");
    channel_for_build_version(&version)
}

/// A single asset attached to a GitHub release. Only the fields
/// [`select_release`] needs; every other field GitHub sends is ignored.
#[derive(Debug, Clone, Deserialize)]
pub struct GithubAsset {
    pub name: String,
    pub browser_download_url: String,
}

/// A minimal view of a GitHub REST API release object. Unknown fields are
/// ignored so an API response can grow without breaking parsing.
#[derive(Debug, Clone, Deserialize)]
pub struct GithubRelease {
    pub tag_name: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub prerelease: bool,
    pub html_url: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub published_at: Option<String>,
    #[serde(default)]
    pub assets: Vec<GithubAsset>,
}

/// The release [`select_release`] picked for a channel: everything spec-18
/// (UI) and spec-17 (the updater plugin) need to describe and fetch it.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedRelease {
    pub version: semver::Version,
    pub tag: String,
    pub release_url: String,
    pub notes: Option<String>,
    pub published_at: Option<String>,
    pub manifest_url: Url,
}

/// Whether a newer release than the running build is available.
///
/// `ResolvedRelease` carries a `semver::Version` plus several owned
/// `String`s, so `Available`'s payload is meaningfully larger than
/// `UpToDate`'s — expected and fine for a value returned once per check
/// and immediately consumed, not stored in a hot collection; boxing it
/// would only obscure the shape spec-16 defines this type with.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum Availability {
    UpToDate,
    Available(ResolvedRelease),
}

/// Errors [`fetch_releases`] can return. `Display` carries the exact
/// user-facing sentence spec-18 shows verbatim; any lower-level detail
/// (status code, response snippet, transport error) stays in the variant
/// for logs, not in `Display`.
#[derive(Debug, Clone, thiserror::Error)]
pub enum UpdateError {
    #[error("Kallilex couldn't reach GitHub to check for updates.")]
    Network(String),
    #[error("GitHub is rate-limiting update checks from this network — try again in an hour.")]
    RateLimited,
    #[error("GitHub returned an unexpected response while checking for updates.")]
    InvalidResponse(String),
}

/// Builds `{api_base}/repos/LStoneyy/kallilex/releases?per_page=30`,
/// tolerating a trailing slash (or not) on `api_base`.
fn releases_url(api_base: &Url) -> Result<Url, UpdateError> {
    let base = api_base.as_str().trim_end_matches('/');
    let full = format!("{base}/repos/{REPO_PATH}/releases?per_page=30");
    Url::parse(&full).map_err(|e| UpdateError::InvalidResponse(e.to_string()))
}

/// Fetches the repository's releases (newest first, up to 30) from the
/// GitHub REST API rooted at `api_base` (production code points this at
/// `https://api.github.com`; tests point it at a `wiremock` server).
/// Unauthenticated — 60 requests/hour/IP is far above one check per day —
/// so a burst of manual checks must degrade into [`UpdateError::RateLimited`],
/// never a crash.
pub async fn fetch_releases(
    client: &reqwest::Client,
    api_base: &Url,
) -> Result<Vec<GithubRelease>, UpdateError> {
    let url = releases_url(api_base)?;

    let response = client
        .get(url)
        .header("User-Agent", user_agent())
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", GITHUB_API_VERSION)
        .timeout(REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(|e| UpdateError::Network(e.to_string()))?;

    let status = response.status();

    if status.is_success() {
        let bytes = response
            .bytes()
            .await
            .map_err(|e| UpdateError::Network(e.to_string()))?;
        return serde_json::from_slice(&bytes)
            .map_err(|e| UpdateError::InvalidResponse(e.to_string()));
    }

    if status.as_u16() == 403 {
        let rate_limited_by_header = response
            .headers()
            .get("x-ratelimit-remaining")
            .and_then(|v| v.to_str().ok())
            == Some("0");
        let body = response.text().await.unwrap_or_default();
        let rate_limited_by_body = body.to_lowercase().contains("rate limit");
        if rate_limited_by_header || rate_limited_by_body {
            return Err(UpdateError::RateLimited);
        }
        return Err(UpdateError::Network(format!("HTTP 403: {body}")));
    }

    let body = response.text().await.unwrap_or_default();
    Err(UpdateError::Network(format!("HTTP {status}: {body}")))
}

/// Picks the newest release this `channel` should offer, or `None` if no
/// release qualifies. See the module's `Testing Decisions` in spec-16 for
/// the exact skip rules this encodes: drafts are always skipped;
/// pre-releases are skipped on `Stable`; a tag that doesn't parse as semver
/// (after stripping one leading `v`) is skipped, never an error; a release
/// with no asset literally named `latest.json` is skipped even if it would
/// otherwise be newest.
pub fn select_release(
    releases: &[GithubRelease],
    channel: UpdateChannel,
) -> Option<ResolvedRelease> {
    releases
        .iter()
        .filter(|release| !release.draft)
        .filter(|release| !release.prerelease || channel == UpdateChannel::Preview)
        .filter_map(|release| {
            let version_str = release
                .tag_name
                .strip_prefix('v')
                .unwrap_or(&release.tag_name);
            let version = semver::Version::parse(version_str).ok()?;
            let manifest_asset = release
                .assets
                .iter()
                .find(|asset| asset.name == "latest.json")?;
            let manifest_url = Url::parse(&manifest_asset.browser_download_url).ok()?;
            Some(ResolvedRelease {
                version,
                tag: release.tag_name.clone(),
                release_url: release.html_url.clone(),
                notes: release.body.clone(),
                published_at: release.published_at.clone(),
                manifest_url,
            })
        })
        .max_by(|a, b| a.version.cmp(&b.version))
}

/// Compares `resolved` (the newest release [`select_release`] picked, if
/// any) against `current` (the running build's version). Strict semver
/// ordering, including pre-release ordering: available iff
/// `resolved.version > current`.
pub fn evaluate(resolved: Option<&ResolvedRelease>, current: &semver::Version) -> Availability {
    match resolved {
        Some(release) if &release.version > current => Availability::Available(release.clone()),
        _ => Availability::UpToDate,
    }
}

/// Which kind of moment is asking whether a check is due:
/// [`Tick::Startup`] fires once per app launch (the only moment
/// `UpdateCheckFrequency::OnLaunch` triggers a check); [`Tick::Periodic`]
/// fires on the scheduler's recurring timer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tick {
    Startup,
    Periodic,
}

/// Whether a scheduled update check is due right now, given `frequency`,
/// the last check's timestamp (`None` if there has never been one), the
/// current time, and which kind of `tick` is asking. Pure — the timer and
/// the actual network call are the scheduler's job (spec-17).
pub fn is_check_due(
    frequency: UpdateCheckFrequency,
    last_check_at: Option<u64>,
    now: u64,
    tick: Tick,
) -> bool {
    match frequency {
        UpdateCheckFrequency::Never => false,
        UpdateCheckFrequency::OnLaunch => tick == Tick::Startup,
        UpdateCheckFrequency::Daily => due_after(last_check_at, now, 86_400),
        UpdateCheckFrequency::Weekly => due_after(last_check_at, now, 604_800),
    }
}

fn due_after(last_check_at: Option<u64>, now: u64, threshold_secs: u64) -> bool {
    match last_check_at {
        None => true,
        Some(last) => now.saturating_sub(last) >= threshold_secs,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn version(s: &str) -> semver::Version {
        semver::Version::parse(s).unwrap()
    }

    fn asset(name: &str, url: &str) -> GithubAsset {
        GithubAsset {
            name: name.to_string(),
            browser_download_url: url.to_string(),
        }
    }

    fn release(
        tag: &str,
        draft: bool,
        prerelease: bool,
        assets: Vec<GithubAsset>,
    ) -> GithubRelease {
        GithubRelease {
            tag_name: tag.to_string(),
            draft,
            prerelease,
            html_url: format!("https://github.com/{REPO_PATH}/releases/tag/{tag}"),
            body: Some("notes".to_string()),
            published_at: Some("2024-01-01T00:00:00Z".to_string()),
            assets,
        }
    }

    fn release_with_manifest(tag: &str, draft: bool, prerelease: bool) -> GithubRelease {
        release(
            tag,
            draft,
            prerelease,
            vec![asset(
                "latest.json",
                &format!("https://github.com/{REPO_PATH}/releases/download/{tag}/latest.json"),
            )],
        )
    }

    // --- channel_for_build_version ---------------------------------

    #[test]
    fn channel_for_build_version_stable_has_no_pre_release_suffix() {
        assert_eq!(
            channel_for_build_version(&version("0.6.0")),
            UpdateChannel::Stable
        );
    }

    #[test]
    fn channel_for_build_version_beta_is_preview() {
        assert_eq!(
            channel_for_build_version(&version("0.6.0-beta.1")),
            UpdateChannel::Preview
        );
    }

    #[test]
    fn channel_for_build_version_rc_is_preview() {
        assert_eq!(
            channel_for_build_version(&version("1.0.0-rc.1")),
            UpdateChannel::Preview
        );
    }

    // --- select_release ----------------------------------------------

    #[test]
    fn select_release_skips_drafts() {
        let releases = vec![release_with_manifest("v0.6.0", true, false)];
        assert_eq!(select_release(&releases, UpdateChannel::Stable), None);
    }

    #[test]
    fn select_release_skips_prereleases_on_stable() {
        let releases = vec![release_with_manifest("v0.6.0-beta.1", false, true)];
        assert_eq!(select_release(&releases, UpdateChannel::Stable), None);
    }

    #[test]
    fn select_release_includes_prereleases_on_preview() {
        let releases = vec![release_with_manifest("v0.6.0-beta.1", false, true)];
        let resolved = select_release(&releases, UpdateChannel::Preview).unwrap();
        assert_eq!(resolved.version, version("0.6.0-beta.1"));
    }

    #[test]
    fn select_release_newest_wins_regardless_of_list_order() {
        let releases = vec![
            release_with_manifest("v0.5.0", false, false),
            release_with_manifest("v0.7.0", false, false),
            release_with_manifest("v0.6.0", false, false),
        ];
        let resolved = select_release(&releases, UpdateChannel::Stable).unwrap();
        assert_eq!(resolved.version, version("0.7.0"));
    }

    #[test]
    fn select_release_stable_newer_than_prerelease_wins_on_preview() {
        let releases = vec![
            release_with_manifest("v0.6.0-beta.5", false, true),
            release_with_manifest("v0.6.0", false, false),
        ];
        let resolved = select_release(&releases, UpdateChannel::Preview).unwrap();
        assert_eq!(resolved.version, version("0.6.0"));
    }

    #[test]
    fn select_release_skips_releases_without_latest_json_even_when_newest() {
        let releases = vec![
            release_with_manifest("v0.6.0", false, false),
            release("v0.7.0", false, false, vec![]),
        ];
        let resolved = select_release(&releases, UpdateChannel::Stable).unwrap();
        assert_eq!(resolved.version, version("0.6.0"));
    }

    #[test]
    fn select_release_skips_unparseable_tags() {
        let releases = vec![release_with_manifest("not-a-version", false, false)];
        assert_eq!(select_release(&releases, UpdateChannel::Stable), None);
    }

    #[test]
    fn select_release_empty_list_is_none() {
        assert_eq!(select_release(&[], UpdateChannel::Stable), None);
    }

    // --- evaluate ------------------------------------------------------

    #[test]
    fn evaluate_current_prerelease_ahead_of_older_stable_is_up_to_date() {
        let resolved = select_release(
            &[release_with_manifest("v0.5.0", false, false)],
            UpdateChannel::Stable,
        );
        let availability = evaluate(resolved.as_ref(), &version("0.6.0-beta.2"));
        assert_eq!(availability, Availability::UpToDate);
    }

    #[test]
    fn evaluate_final_release_newer_than_current_beta_is_available() {
        let resolved = select_release(
            &[release_with_manifest("v0.6.0", false, false)],
            UpdateChannel::Preview,
        );
        let availability = evaluate(resolved.as_ref(), &version("0.6.0-beta.2"));
        assert!(matches!(availability, Availability::Available(_)));
    }

    #[test]
    fn evaluate_without_any_resolved_release_is_up_to_date() {
        assert_eq!(evaluate(None, &version("0.6.0")), Availability::UpToDate);
    }

    #[test]
    fn evaluate_equal_version_is_up_to_date() {
        let resolved = select_release(
            &[release_with_manifest("v0.6.0", false, false)],
            UpdateChannel::Stable,
        );
        let availability = evaluate(resolved.as_ref(), &version("0.6.0"));
        assert_eq!(availability, Availability::UpToDate);
    }

    // --- fetch_releases --------------------------------------------

    fn realistic_release_json() -> serde_json::Value {
        serde_json::json!({
            "url": "https://api.github.com/repos/LStoneyy/kallilex/releases/1",
            "id": 1,
            "tag_name": "v0.6.0",
            "target_commitish": "main",
            "name": "0.6.0",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/LStoneyy/kallilex/releases/tag/v0.6.0",
            "body": "Release notes",
            "published_at": "2024-05-01T00:00:00Z",
            "author": { "login": "someone" },
            "assets": [
                {
                    "name": "latest.json",
                    "browser_download_url": "https://github.com/LStoneyy/kallilex/releases/download/v0.6.0/latest.json",
                    "size": 123,
                    "content_type": "application/json"
                }
            ]
        })
    }

    #[tokio::test]
    async fn fetch_releases_parses_a_realistic_200_response() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/repos/{REPO_PATH}/releases")))
            .and(query_param("per_page", "30"))
            .and(header("accept", "application/vnd.github+json"))
            .and(header("user-agent", user_agent().as_str()))
            .respond_with(ResponseTemplate::new(200).set_body_json(vec![realistic_release_json()]))
            .expect(1)
            .mount(&server)
            .await;

        let client = reqwest::Client::new();
        let api_base = Url::parse(&server.uri()).unwrap();
        let releases = fetch_releases(&client, &api_base).await.unwrap();

        assert_eq!(releases.len(), 1);
        assert_eq!(releases[0].tag_name, "v0.6.0");
        assert_eq!(releases[0].assets[0].name, "latest.json");
    }

    #[tokio::test]
    async fn fetch_releases_tolerates_a_trailing_slash_on_api_base() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/repos/{REPO_PATH}/releases")))
            .respond_with(ResponseTemplate::new(200).set_body_json(Vec::<serde_json::Value>::new()))
            .mount(&server)
            .await;

        let client = reqwest::Client::new();
        let api_base = Url::parse(&format!("{}/", server.uri())).unwrap();
        let releases = fetch_releases(&client, &api_base).await.unwrap();

        assert!(releases.is_empty());
    }

    #[tokio::test]
    async fn fetch_releases_403_with_zero_remaining_is_rate_limited() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/repos/{REPO_PATH}/releases")))
            .respond_with(
                ResponseTemplate::new(403)
                    .insert_header("x-ratelimit-remaining", "0")
                    .set_body_string("API rate limit exceeded"),
            )
            .mount(&server)
            .await;

        let client = reqwest::Client::new();
        let api_base = Url::parse(&server.uri()).unwrap();
        let result = fetch_releases(&client, &api_base).await;

        assert!(
            matches!(result, Err(UpdateError::RateLimited)),
            "{result:?}"
        );
    }

    #[tokio::test]
    async fn fetch_releases_500_is_network() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/repos/{REPO_PATH}/releases")))
            .respond_with(ResponseTemplate::new(500).set_body_string("boom"))
            .mount(&server)
            .await;

        let client = reqwest::Client::new();
        let api_base = Url::parse(&server.uri()).unwrap();
        let result = fetch_releases(&client, &api_base).await;

        assert!(matches!(result, Err(UpdateError::Network(_))), "{result:?}");
    }

    #[tokio::test]
    async fn fetch_releases_malformed_json_is_invalid_response() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/repos/{REPO_PATH}/releases")))
            .respond_with(ResponseTemplate::new(200).set_body_string("not json"))
            .mount(&server)
            .await;

        let client = reqwest::Client::new();
        let api_base = Url::parse(&server.uri()).unwrap();
        let result = fetch_releases(&client, &api_base).await;

        assert!(
            matches!(result, Err(UpdateError::InvalidResponse(_))),
            "{result:?}"
        );
    }

    // --- is_check_due ----------------------------------------------

    #[test]
    fn is_check_due_never_is_always_false() {
        for tick in [Tick::Startup, Tick::Periodic] {
            for last in [None, Some(0), Some(1_000_000)] {
                assert!(!is_check_due(
                    UpdateCheckFrequency::Never,
                    last,
                    1_000_000,
                    tick
                ));
            }
        }
    }

    #[test]
    fn is_check_due_on_launch_only_fires_on_startup() {
        assert!(is_check_due(
            UpdateCheckFrequency::OnLaunch,
            None,
            1_000,
            Tick::Startup
        ));
        assert!(is_check_due(
            UpdateCheckFrequency::OnLaunch,
            Some(999),
            1_000,
            Tick::Startup
        ));
        assert!(!is_check_due(
            UpdateCheckFrequency::OnLaunch,
            None,
            1_000,
            Tick::Periodic
        ));
        assert!(!is_check_due(
            UpdateCheckFrequency::OnLaunch,
            Some(999),
            1_000,
            Tick::Periodic
        ));
    }

    #[test]
    fn is_check_due_daily_matrix() {
        for tick in [Tick::Startup, Tick::Periodic] {
            // Never checked before.
            assert!(is_check_due(UpdateCheckFrequency::Daily, None, 1_000, tick));
            // Checked just now.
            assert!(!is_check_due(
                UpdateCheckFrequency::Daily,
                Some(1_000),
                1_000,
                tick
            ));
            // Exactly at the threshold.
            assert!(is_check_due(
                UpdateCheckFrequency::Daily,
                Some(0),
                86_400,
                tick
            ));
            // Just under the threshold.
            assert!(!is_check_due(
                UpdateCheckFrequency::Daily,
                Some(0),
                86_399,
                tick
            ));
            // Just past the threshold.
            assert!(is_check_due(
                UpdateCheckFrequency::Daily,
                Some(0),
                86_401,
                tick
            ));
        }
    }

    #[test]
    fn is_check_due_weekly_matrix() {
        for tick in [Tick::Startup, Tick::Periodic] {
            assert!(is_check_due(
                UpdateCheckFrequency::Weekly,
                None,
                1_000,
                tick
            ));
            assert!(!is_check_due(
                UpdateCheckFrequency::Weekly,
                Some(1_000),
                1_000,
                tick
            ));
            assert!(is_check_due(
                UpdateCheckFrequency::Weekly,
                Some(0),
                604_800,
                tick
            ));
            assert!(!is_check_due(
                UpdateCheckFrequency::Weekly,
                Some(0),
                604_799,
                tick
            ));
            assert!(is_check_due(
                UpdateCheckFrequency::Weekly,
                Some(0),
                604_801,
                tick
            ));
        }
    }
}
