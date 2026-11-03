//! Test-only helper for loading the language-neutral contract fixtures in
//! `contracts/` (sibling to `src-tauri/`), shared with the iOS port's Swift
//! test suite. See `issues-ios/spec-ios-03-contract-fixtures.md`.
//!
//! Never used from production code — only from `#[cfg(test)] mod tests` in
//! `prompts.rs`, `providers/mod.rs` and `providers/openai.rs`.

use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;

/// Absolute path to `filename` inside the repo's `contracts/` directory,
/// resolved from `CARGO_MANIFEST_DIR` so it works regardless of the test
/// runner's current directory, on Windows, Linux and macOS alike.
pub fn fixture_path(filename: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../contracts")
        .join(filename)
}

/// Reads `filename` from `contracts/` as a UTF-8 string, panicking with the
/// resolved path on failure so a missing/misnamed fixture is easy to spot.
pub fn read_fixture(filename: &str) -> String {
    let path = fixture_path(filename);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read fixture {}: {e}", path.display()))
}

/// Reads and parses `filename` from `contracts/` as JSON, panicking with the
/// resolved path on failure (missing file or schema mismatch).
pub fn load_json<T: DeserializeOwned>(filename: &str) -> T {
    let path = fixture_path(filename);
    let contents = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read fixture {}: {e}", path.display()));
    serde_json::from_str(&contents)
        .unwrap_or_else(|e| panic!("failed to parse fixture {}: {e}", path.display()))
}
