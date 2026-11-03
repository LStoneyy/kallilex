import Foundation

/// The single `JSONEncoder`/`JSONDecoder` configuration every
/// `SettingsStore` implementation uses, so `AppSettings` and its nested
/// models round-trip consistently (ISO-8601 dates) regardless of which
/// store wrote or read them.
enum SettingsJSONCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
