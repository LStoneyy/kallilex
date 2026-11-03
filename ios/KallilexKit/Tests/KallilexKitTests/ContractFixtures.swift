import Foundation

/// Test-only helper for loading the language-neutral contract fixtures in
/// `contracts/` (repo root, sibling to `src-tauri/` and `ios/`) — shared
/// with the Rust core's test suite so neither platform drifts from the
/// other. See `issues-ios/spec-ios-03-contract-fixtures.md`.
///
/// Never used by production `KallilexKit` code — test-only.
enum ContractFixtures {
    struct LookupError: Swift.Error, CustomStringConvertible {
        let description: String
    }

    /// Walks up from `filePath` (defaulting to `#filePath`) until a
    /// directory containing a `contracts` subdirectory is found, and
    /// returns that directory — the repo root. A `#filePath` default
    /// argument is resolved at its call site, not at this declaration;
    /// the only call site in this package is `url(_:)` below, inside
    /// this very file, so in practice the walk always starts from this
    /// file's own directory (`Tests/KallilexKitTests/`), regardless of
    /// which test file ultimately triggers the lookup.
    static func repoRoot(from filePath: String = #filePath) throws -> URL {
        var current = URL(fileURLWithPath: filePath).deletingLastPathComponent()

        while current.path != "/" {
            let contractsDir = current.appending(path: "contracts")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: contractsDir.path,
                isDirectory: &isDirectory
            )
            if exists, isDirectory.boolValue {
                return current
            }
            current = current.deletingLastPathComponent()
        }

        throw LookupError(
            description: "Could not find a contracts/ directory walking up from \(filePath)"
        )
    }

    /// The absolute file URL of `name` inside `contracts/`.
    static func url(_ name: String) throws -> URL {
        try repoRoot().appending(path: "contracts/\(name)")
    }

    /// Raw bytes of fixture `name`.
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try url(name))
    }

    /// Fixture `name` decoded as a UTF-8 string, exactly as written on
    /// disk (no trimming).
    static func text(_ name: String) throws -> String {
        guard let text = String(data: try data(name), encoding: .utf8) else {
            throw LookupError(description: "\(name) is not valid UTF-8")
        }
        return text
    }

    /// Fixture `name` decoded as JSON into `type`.
    static func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: try data(name))
    }
}
