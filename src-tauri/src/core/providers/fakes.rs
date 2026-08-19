//! In-memory `Provider` fake used by unit tests in this module (and,
//! later, at the command level).

use std::sync::Mutex;

use super::{Provider, ProviderError, ProviderProfile};

/// One recorded call to [`FakeProvider::complete`].
#[derive(Debug, Clone, PartialEq)]
pub struct RecordedCall {
    pub profile_id: String,
    pub api_key: Option<String>,
    pub system_prompt: String,
    pub user_text: String,
}

enum Outcome {
    Ok(String),
    Err(ProviderError),
}

/// Configurable `Provider` fake: returns a canned `Ok` text or a canned
/// error, and records every call it received, in order.
pub struct FakeProvider {
    outcome: Outcome,
    calls: Mutex<Vec<RecordedCall>>,
}

impl FakeProvider {
    pub fn returning(text: impl Into<String>) -> Self {
        Self {
            outcome: Outcome::Ok(text.into()),
            calls: Mutex::new(Vec::new()),
        }
    }

    pub fn failing(err: ProviderError) -> Self {
        Self {
            outcome: Outcome::Err(err),
            calls: Mutex::new(Vec::new()),
        }
    }

    pub fn calls(&self) -> Vec<RecordedCall> {
        self.calls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

impl Provider for FakeProvider {
    fn complete(
        &self,
        profile: &ProviderProfile,
        api_key: Option<&str>,
        system_prompt: &str,
        user_text: &str,
    ) -> impl std::future::Future<Output = Result<String, ProviderError>> + Send {
        self.calls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(RecordedCall {
                profile_id: profile.id.clone(),
                api_key: api_key.map(|s| s.to_string()),
                system_prompt: system_prompt.to_string(),
                user_text: user_text.to_string(),
            });

        let result = match &self.outcome {
            Outcome::Ok(text) => Ok(text.clone()),
            Outcome::Err(err) => Err(err.clone()),
        };

        async move { result }
    }
}
