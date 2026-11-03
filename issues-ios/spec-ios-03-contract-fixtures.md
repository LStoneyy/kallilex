# Spec ios-03 — Contract fixtures

Status: ready-for-agent
Phase: Phase 1 (Foundation)
Depends on: ios-02 (Xcode project and KallilexKit exist)

## Problem Statement

The iOS app's Swift port of desktop logic (prompt assembly, privacy
classification, OpenAI request/response handling) must not drift from the Rust
core. Contract fixtures — language-neutral JSON test data — loaded by both Rust
and Swift test suites enforce consistency. The fixtures are the single source
of truth for exact instruction text, default prompts, privacy rules and HTTP
request/response shapes.

## Solution

Create language-neutral JSON fixture files in `contracts/` with the exact
behavior extracted from the desktop code. Write fixture loaders:

- Rust test code only (no production changes to desktop) in
  `src-tauri/src/core/` that loads and tests against the fixtures
- Swift test code in `KallilexKit/Tests/` that loads the same fixtures via
  `#filePath`

The fixtures stay committed in the repo and are maintained alongside future
changes to either platform. Swift assertions against `KallilexKit` logic are
written in ios-05, not here.

## User Stories

1. As a test author, I want the exact default prompts and instruction
   text from the desktop in a single source of truth, so that both platforms
   are tested against the same contract.
2. As a tester, I want comprehensive privacy-classification test cases
   (loopback, private IPs, link-local, ULA, domain suffixes, single-label
   hosts, public domains), so that I can verify both platforms handle
   edge cases the same way.
3. As a protocol developer, I want the exact OpenAI request structure
   (headers, timeout, custom headers, missing model) and response parsing
   rules (strip_padding cases, truncation, error messages), so that a
   backend change never breaks one platform undetected.
4. As a maintainer, I want one place to update prompt text (or instruction
   format changes), so that syncing it to both platforms is a simple JSON edit.

## Implementation Decisions

### Fixture files in `contracts/`

All files are JSON, UTF-8, committed to the repo, and loaded by test code
only (not production code).

#### `contracts/default-prompts.json`

Seeded prompts with exact instructions from desktop. Extracted from
`src-tauri/src/core/prompts.rs` `default_prompts()`. Compare on `id`, `label`,
and `instruction` only (not `shortcut`, which is desktop-only):

```json
[
  {
    "id": "builtin-rewrite",
    "label": "Rewrite",
    "instruction": "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone."
  },
  {
    "id": "builtin-shorten",
    "label": "Shorten",
    "instruction": "Make the user's text noticeably shorter while keeping its essential meaning and tone."
  },
  {
    "id": "builtin-improve-clarity",
    "label": "Improve clarity",
    "instruction": "Make the user's text clearer and easier to understand without changing its meaning."
  }
]
```

#### `contracts/return-only-text-instruction.txt`

The exact suffix appended to every prompt (from `RETURN_ONLY_TEXT_INSTRUCTION`
in `src-tauri/src/core/providers/mod.rs`):

```
Return only the transformed text, with no preamble, commentary, or surrounding quotes. Preserve the text's original language. Preserve the text's structure and formatting exactly: keep paragraph breaks, line breaks, list markers, indentation, and any markup characters (e.g. Markdown) that appear in the input.
```

#### `contracts/prompt-assembly.json`

Input actions and their expected assembled system prompts. One object per case:

```json
[
  {
    "kind": "prompt",
    "instruction": "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone.",
    "expected": "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone. Return only the transformed text, with no preamble, commentary, or surrounding quotes. Preserve the text's original language. Preserve the text's structure and formatting exactly: keep paragraph breaks, line breaks, list markers, indentation, and any markup characters (e.g. Markdown) that appear in the input."
  },
  {
    "kind": "custom",
    "instruction": "Translate to French",
    "expected": "Apply the following instruction to the user's text: Translate to French Return only the transformed text, with no preamble, commentary, or surrounding quotes. Preserve the text's original language. Preserve the text's structure and formatting exactly: keep paragraph breaks, line breaks, list markers, indentation, and any markup characters (e.g. Markdown) that appear in the input."
  }
]
```

#### `contracts/privacy-classification.json`

Base URLs and their expected privacy class. Covers:

- Loopback (IPv4 and IPv6): `http://localhost`, `http://127.0.0.1`, `http://[::1]`
- IPv4 private and link-local: `http://10.0.0.5`, `http://192.168.1.10`,
  `http://172.16.0.1`, `http://169.254.1.1`
- IPv6 unique-local and link-local: `http://[fc00::1]`, `http://[fe80::1]`
- Domain suffixes (`.local`, `.lan`, `.home`, `.internal`): all "lan"
- Single-label hostnames: all "lan" (e.g., `http://aiserver`)
- Localhost variants: `http://foo.localhost`
- Public hosts and domains: "cloud" (e.g., `https://api.openai.com`,
  `http://8.8.8.8`)
- Trailing dots and case-insensitivity: `http://example.com.` and
  `http://EXAMPLE.COM` both classify the same

```json
[
  { "baseUrl": "http://localhost:11434/v1", "expected": "local" },
  { "baseUrl": "http://127.0.0.1:1234/v1", "expected": "local" },
  { "baseUrl": "http://[::1]:8080/v1", "expected": "local" },
  { "baseUrl": "http://foo.localhost/v1", "expected": "local" },
  { "baseUrl": "http://10.0.0.5/v1", "expected": "lan" },
  { "baseUrl": "http://192.168.1.10:8080/v1", "expected": "lan" },
  { "baseUrl": "http://169.254.1.1/v1", "expected": "lan" },
  { "baseUrl": "http://[fc00::1]/v1", "expected": "lan" },
  { "baseUrl": "http://[fe80::1]/v1", "expected": "lan" },
  { "baseUrl": "http://foo.local/v1", "expected": "lan" },
  { "baseUrl": "http://foo.lan/v1", "expected": "lan" },
  { "baseUrl": "http://foo.home/v1", "expected": "lan" },
  { "baseUrl": "http://foo.internal/v1", "expected": "lan" },
  { "baseUrl": "http://aiserver/v1", "expected": "lan" },
  { "baseUrl": "http://aiserver:8080/v1", "expected": "lan" },
  { "baseUrl": "https://api.openai.com/v1", "expected": "cloud" },
  { "baseUrl": "http://8.8.8.8/v1", "expected": "cloud" },
  { "baseUrl": "https://example.com/v1", "expected": "cloud" },
  { "baseUrl": "http://example.com./v1", "expected": "cloud" },
  { "baseUrl": "http://EXAMPLE.COM/v1", "expected": "cloud" },
  { "baseUrl": "http://[::ffff:127.0.0.1]/v1", "expected": "cloud" },
  { "baseUrl": "not a url", "expected": null },
  { "baseUrl": "", "expected": null }
]
```

Parseable URLs with a valid host return "local", "lan", or "cloud". Unparseable
URLs (no URL, invalid syntax) have `expected: null`.

#### `contracts/openai-endpoint.json`

Endpoint building test cases: base URLs and expected results.

```json
[
  {
    "baseUrl": "http://localhost:11434/v1",
    "expected": "http://localhost:11434/v1/chat/completions"
  },
  {
    "baseUrl": "http://localhost:11434/v1/",
    "expected": "http://localhost:11434/v1/chat/completions"
  },
  {
    "baseUrl": "https://api.openai.com/v1",
    "expected": "https://api.openai.com/v1/chat/completions"
  },
  {
    "baseUrl": "ftp://invalid",
    "shouldError": true,
    "errorKind": "invalidBaseUrl"
  },
  {
    "baseUrl": "not a url",
    "shouldError": true,
    "errorKind": "invalidBaseUrl"
  }
]
```

#### `contracts/openai-request.json`

Every case lists all inputs explicitly (`baseUrl`, `model`, `apiKey`
— a string or `null` —, `customHeaders`, `systemPrompt`, `userText`); there
are no implicit defaults. Cases with `expectedBody` / `expectedHeaders` send
a real request: the test substitutes the mock server's URL (wiremock in
Rust, the `URLProtocol` stub in Swift) for the host part of `baseUrl`,
keeping the `/v1` path, and asserts the captured request: the JSON body
equals `expectedBody` (when present), every header in `expectedHeaders` is
present with that value, and no header in `expectedAbsentHeaders` is sent.
Cases with `expectedErrorKind` and `expectNoRequest: true` must fail with
that kind without any request reaching the mock. The header rules mirror
reqwest: a header whose name is blank or not a valid token, or whose value
contains characters outside tab and 0x20–0x7E (here a line break), is
skipped silently.

```json
[
  {
    "name": "bearer token and custom header",
    "baseUrl": "https://api.example.com/v1",
    "model": "test-model",
    "apiKey": "test-key",
    "customHeaders": [
      {
        "name": "X-Custom",
        "value": "custom-value"
      }
    ],
    "systemPrompt": "Fix the text.",
    "userText": "Hello world",
    "expectedBody": {
      "model": "test-model",
      "messages": [
        {
          "role": "system",
          "content": "Fix the text."
        },
        {
          "role": "user",
          "content": "Hello world"
        }
      ],
      "stream": false
    },
    "expectedHeaders": {
      "Authorization": "Bearer test-key",
      "X-Custom": "custom-value"
    },
    "expectedAbsentHeaders": []
  },
  {
    "name": "no key sends no Authorization header",
    "baseUrl": "https://api.example.com/v1",
    "model": "test-model",
    "apiKey": null,
    "customHeaders": [],
    "systemPrompt": "Fix the text.",
    "userText": "Hello world",
    "expectedBody": {
      "model": "test-model",
      "messages": [
        {
          "role": "system",
          "content": "Fix the text."
        },
        {
          "role": "user",
          "content": "Hello world"
        }
      ],
      "stream": false
    },
    "expectedHeaders": {},
    "expectedAbsentHeaders": [
      "Authorization"
    ]
  },
  {
    "name": "custom header with blank name is skipped",
    "baseUrl": "https://api.example.com/v1",
    "model": "test-model",
    "apiKey": "test-key",
    "customHeaders": [
      {
        "name": "  ",
        "value": "ignored"
      },
      {
        "name": "X-Valid",
        "value": "used"
      }
    ],
    "systemPrompt": "Fix the text.",
    "userText": "Hello world",
    "expectedHeaders": {
      "Authorization": "Bearer test-key",
      "X-Valid": "used"
    },
    "expectedAbsentHeaders": []
  },
  {
    "name": "custom header with invalid value is skipped",
    "baseUrl": "https://api.example.com/v1",
    "model": "test-model",
    "apiKey": "test-key",
    "customHeaders": [
      {
        "name": "X-Bad",
        "value": "line\nbreak"
      },
      {
        "name": "X-Valid",
        "value": "used"
      }
    ],
    "systemPrompt": "Fix the text.",
    "userText": "Hello world",
    "expectedHeaders": {
      "Authorization": "Bearer test-key",
      "X-Valid": "used"
    },
    "expectedAbsentHeaders": [
      "X-Bad"
    ]
  },
  {
    "name": "blank model fails before any request",
    "baseUrl": "https://api.example.com/v1",
    "model": "  ",
    "apiKey": "test-key",
    "customHeaders": [],
    "systemPrompt": "Fix the text.",
    "userText": "Hello world",
    "expectedErrorKind": "missingModel",
    "expectNoRequest": true
  },
  {
    "name": "invalid base URL is reported before a blank model",
    "baseUrl": "ftp://example.com/v1",
    "model": "  ",
    "apiKey": null,
    "customHeaders": [],
    "systemPrompt": "Fix the text.",
    "userText": "Hello world",
    "expectedErrorKind": "invalidBaseUrl",
    "expectNoRequest": true
  }
]
```

(Order matters: an invalid base URL is checked before a blank model.)

#### `contracts/openai-response.json`

Response parsing and padding cases, plus HTTP error cases. Tested via the full
request path with `wiremock` (Rust) or `URLProtocol` (Swift) serving each
fixture's body and status. Fixtures:

```json
[
  {
    "name": "success with padding",
    "status": 200,
    "body": "{\"choices\": [{\"message\": {\"role\": \"assistant\", \"content\": \"\\n\\nHello there  \"}}]}",
    "expectedText": "Hello there",
    "description": "Leading blank lines and trailing whitespace stripped, first line indentation preserved"
  },
  {
    "name": "CRLF line endings",
    "status": 200,
    "body": "{\"choices\": [{\"message\": {\"content\": \"\\r\\n\\r\\n  hi\\r\\n\"}}]}",
    "expectedText": "  hi",
    "description": "CRLF stripped like LF; indentation preserved"
  },
  {
    "name": "multiline with indentation",
    "status": 200,
    "body": "{\"choices\": [{\"message\": {\"content\": \"\\nLine one\\n\\n    indented\\n\"}}]}",
    "expectedText": "Line one\n\n    indented",
    "description": "Interior blank lines and indentation kept, leading blank lines and trailing whitespace stripped"
  },
  {
    "name": "single indented line",
    "status": 200,
    "body": "{\"choices\": [{\"message\": {\"content\": \"  indented\"}}]}",
    "expectedText": "  indented",
    "description": "Leading indentation preserved"
  },
  {
    "name": "no choices",
    "status": 200,
    "body": "{\"choices\": []}",
    "shouldError": true,
    "errorKind": "invalidResponse",
    "errorMessageContains": "response contained no choices"
  },
  {
    "name": "missing content",
    "status": 200,
    "body": "{\"choices\": [{\"message\": {\"role\": \"assistant\"}}]}",
    "shouldError": true,
    "errorKind": "invalidResponse",
    "errorMessageContains": "message content was missing or null"
  },
  {
    "name": "null content",
    "status": 200,
    "body": "{\"choices\": [{\"message\": {\"content\": null}}]}",
    "shouldError": true,
    "errorKind": "invalidResponse",
    "errorMessageContains": "message content was missing or null"
  },
  {
    "name": "invalid JSON",
    "status": 200,
    "body": "not json",
    "shouldError": true,
    "errorKind": "invalidResponse"
  },
  {
    "name": "HTTP 500 error",
    "status": 500,
    "body": "(400 ä characters, U+00E4, written out in full in the JSON file)",
    "shouldError": true,
    "errorKind": "http",
    "expectedStatus": 500,
    "expectedSnippetChars": 300,
    "description": "Error snippet is exactly the first 300 Unicode characters of the body; non-ASCII character catches byte-vs-character truncation bugs"
  }
]
```

Error matching: `errorKind` is always required; `errorMessageContains` is
checked only for stable strings. Invalid JSON and HTTP errors don't have
predictable messages (they depend on serde/http client versions).

### Rust test loader

**File:** `src-tauri/src/core/contract_fixtures.rs` (new, test-only helper)

This module defines a helper to locate the `contracts/` directory:

```rust
#[cfg(test)]
pub mod contract_fixtures {
    use std::path::Path;

    pub fn fixture_path(filename: &str) -> String {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../contracts")
            .join(filename)
            .to_string_lossy()
            .to_string()
    }
}
```

**File:** `src-tauri/src/core/mod.rs` (declaration, test-only)

```rust
#[cfg(test)]
pub mod contract_fixtures;
```

**Tests:** Assertions go into the existing `#[cfg(test)] mod tests` of each
module (private items are visible there):

- **`src-tauri/src/core/prompts.rs::tests`**: compare `default_prompts()` (on
  `id`, `label`, `instruction` only) and `assemble_prompt()` cases against
  fixtures.
- **`src-tauri/src/core/providers/mod.rs::tests`**: compare
  `classify_privacy()` against privacy-classification.json. Unparseable URLs
  should return `None`.
- **`src-tauri/src/core/providers/openai.rs::tests`**: for each
  openai-response.json case, serve the `body` with HTTP `status` via `wiremock`
  and call `OpenAiCompatibleAdapter.complete`, checking the result matches
  expected text or error. For openai-request.json, verify headers and body
  structure. For endpoint.json, test the `endpoint()` function.

All tests load fixtures via the helper in `contract_fixtures.rs`. The tests
run as part of `cargo test` and are test-only code.

The only non-test change is the declaration in `core/mod.rs`.

### Swift test loader

**File:** `KallilexKit/Tests/KallilexKitTests/ContractFixturesTests.swift`

Loads the same fixture files from the repo's `contracts/` directory via
`#filePath`. This uses Swift Testing (`import Testing`, not `XCTest`):

```swift
import Testing
@testable import KallilexKit

struct ContractFixturesTests {
    private func findRepoRoot() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests directory
        
        while current.path != "/" {
            let contractsDir = current.appending(path: "contracts")
            if (try? contractsDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        
        throw NSError(domain: "ContractFixturesTests",
                     code: 1,
                     userInfo: [NSLocalizedDescriptionKey:
                      "Could not find contracts/ directory walking up from #filePath"])
    }
    
    @Test("Default prompts match fixture")
    func defaultPromptsMatchFixture() throws {
        let repoRoot = try findRepoRoot()
        let fixtureURL = repoRoot.appending(path: "contracts/default-prompts.json")
        let data = try Data(contentsOf: fixtureURL)
        let expected = try JSONDecoder().decode([CustomPrompt].self, from: data)
        
        let actual = PromptDefaults.defaults(locale: Locale(identifier: "en"))
        #expect(actual == expected)
    }
    
    // Similar tests for privacy-classification, prompt-assembly, openai-response
    // load fixtures from the same repoRoot
}
```

(Simulator tests can read the host filesystem via `#filePath`. This approach
works locally and in CI where the source is available.)

### Fixture file locations and git

- Fixtures live in `contracts/` at the repo root (sibling to `src-tauri/` and
  `ios/`).
- They are committed to git and tracked. No machine-specific data, no secrets.
- Rust tests load them with paths from `contract_fixtures.rs` helper.
- Swift tests locate them via `#filePath` walking up to the repo root.

## Testing Decisions

### Rust (desktop)

Run as part of `cargo test` on every push:

```bash
cargo test --manifest-path src-tauri/Cargo.toml
```

Assertions in the existing test modules (`core::prompts`, `core::providers`,
`core::providers::openai`) load and validate against fixtures:

- `default_prompts()` matches fixture (`id`, `label`, `instruction` only)
- `classify_privacy(url)` matches expected for every URL
- `assemble_prompt(action)` matches expected
- Response parsing (via `wiremock`) handles padding, errors, and HTTP status codes

Passing tests verify that the Rust core honors the contract.

### Swift (iOS)

Run as part of `xcodebuild test` on every push (ios.yml):

```
xcodebuild test -scheme KallilexKit …
```

- Same tests as Rust, using the same fixture files
- Passing tests verify that the Swift port honors the contract

### Maintenance

When the contract changes (e.g., a new prompt is added, instruction text is
refined):

1. Update the fixture file(s) in `contracts/`.
2. Both Rust and Swift tests automatically pick up the change.
3. CI runs both test suites and catches any implementation gaps.

## Out of Scope

- Production code changes to the desktop app (fixtures and tests are test-only).
- Implementing the full iOS logic for prompt assembly, privacy classification
  or OpenAI requests (that comes in ios-05). Swift assertions against
  `KallilexKit` logic are written there, not here.
- Apple Foundation Models or Private Cloud Compute (tested in ios-10).
- Error message strings (matched on `errorKind`, not on message text).

## Further Notes

- PLAN.md §7.2 and §7.3 describe the iOS implementation of prompt assembly,
  privacy classification and the OpenAI provider.
- PLAN.md §12.2 specifies the contract fixture suite and its role in keeping
  the ports in sync.
- Fixture paths in Rust use the `contract_fixtures::fixture_path()` helper.
  The helper constructs the path from `CARGO_MANIFEST_DIR`; test locally with
  `cargo test`.
- The Rust test module `contract_fixtures.rs` is declared in `core/mod.rs` as
  the only non-test change to desktop code.
- Swift assertions against types from ios-05 (`CustomPrompt`, privacy
  classification logic, etc.) are written in ios-05's spec and implementation,
  not here. This spec delivers the fixtures and the fixture-loading helper.
