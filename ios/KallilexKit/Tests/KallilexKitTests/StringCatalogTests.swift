import Foundation
import Testing

/// Catalog completeness tests (ios-11 spec, "Catalog completeness test").
///
/// Walks every `.xcstrings` catalog under `ios/` — the app, the extension,
/// `InfoPlist`, and the package targets — not just `KallilexKit`'s own
/// resources, and checks that every key has a translated German value
/// (unless marked `shouldTranslate: false`), that nothing is left in state
/// `new` or `needs_review` in any language, and that every German value
/// keeps the same set of format specifiers as its English counterpart.

/// Walks up from this file to the repo root (the directory containing
/// `ios/`) and returns every `.xcstrings` catalog under `ios/`, excluding
/// build directories (`ios/build/`, `KallilexKit/.build/`, and any
/// `DerivedData`) so that generated or cached catalogs are never checked.
private func stringCatalogs() throws -> [URL] {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appending(path: "ios").path) {
        let parent = dir.deletingLastPathComponent()
        guard parent != dir else {
            Issue.record("Repo root (directory containing ios/) not found")
            return []
        }
        dir = parent
    }
    let ios = dir.appending(path: "ios")
    let files = FileManager.default.enumerator(at: ios, includingPropertiesForKeys: nil)
    return (files?.allObjects as? [URL] ?? [])
        .filter { url in
            guard url.pathExtension == "xcstrings" else { return false }
            let path = url.path
            return !path.contains("/.build/")
                && !path.contains("/build/")
                && !path.contains("/DerivedData/")
        }
        .sorted { $0.path < $1.path }
}

private struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]
}

private struct Entry: Decodable {
    let shouldTranslate: Bool?
    let localizations: [String: Localization]?
}

private struct Localization: Decodable {
    let stringUnit: StringUnit?
    let variations: [String: [String: Localization]]?  // e.g. plural → one/other
}

private struct StringUnit: Decodable {
    let state: String
    let value: String
}

private func isTranslated(_ l: Localization) -> Bool {
    if let unit = l.stringUnit {
        return unit.state == "translated" && !unit.value.isEmpty
    }
    guard let variations = l.variations, !variations.isEmpty else { return false }
    return variations.values.allSatisfy { $0.values.allSatisfy(isTranslated) }
}

/// Every `stringUnit` leaf reachable from `l`, recursing through plural
/// variations. A plain (non-plural) localization yields at most one.
private func leafStringUnits(_ l: Localization) -> [StringUnit] {
    if let unit = l.stringUnit {
        return [unit]
    }
    guard let variations = l.variations else { return [] }
    return variations.values.flatMap { $0.values.flatMap(leafStringUnits) }
}

/// Extracts format specifiers (`%@`, `%lld`, `%1$@`, …) from `value`, in
/// the order they appear. A literal `%%` is dropped, since it isn't an
/// argument placeholder.
private func formatSpecifiers(_ value: String) -> [String] {
    let pattern = #"%(?:\d+\$)?(?:lld|llu|ld|lu|lf|[@dDuUxXoOfFeEgGcCsSp%])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(value.startIndex..., in: value)
    return regex.matches(in: value, range: range)
        .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
        .filter { $0 != "%%" }
}

/// Guards against every other test in this file vacuously passing because
/// `stringCatalogs()` found nothing — if this fails, something broke the
/// repo-root walk or the catalogs went missing, not the translations
/// themselves.
@Test
func atLeastOneStringCatalogExists() throws {
    let catalogs = try stringCatalogs()
    #expect(!catalogs.isEmpty, "No .xcstrings catalogs found under ios/")
}

@Test(arguments: try stringCatalogs())
func catalogHasGermanForEveryKey(_ url: URL) throws {
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    for (key, entry) in catalog.strings where entry.shouldTranslate != false {
        let de = entry.localizations?["de"]
        #expect(
            de.map(isTranslated) == true,
            "\(url.lastPathComponent): \"\(key)\" has no translated German value"
        )
    }
}

@Test(arguments: try stringCatalogs())
func catalogHasNoNewOrNeedsReviewStates(_ url: URL) throws {
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    for (key, entry) in catalog.strings {
        for (language, localization) in entry.localizations ?? [:] {
            for unit in leafStringUnits(localization) {
                #expect(
                    unit.state != "new" && unit.state != "needs_review",
                    "\(url.lastPathComponent): \"\(key)\" (\(language)) is in state \"\(unit.state)\""
                )
            }
        }
    }
}

@Test(arguments: try stringCatalogs())
func germanKeepsTheSameFormatSpecifiersAsEnglish(_ url: URL) throws {
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    for (key, entry) in catalog.strings where entry.shouldTranslate != false {
        guard let en = entry.localizations?["en"], let de = entry.localizations?["de"] else { continue }
        let enSpecifiers = leafStringUnits(en).flatMap { formatSpecifiers($0.value) }.sorted()
        let deSpecifiers = leafStringUnits(de).flatMap { formatSpecifiers($0.value) }.sorted()
        #expect(
            enSpecifiers == deSpecifiers,
            "\(url.lastPathComponent): \"\(key)\" German format specifiers \(deSpecifiers) don't match English \(enSpecifiers)"
        )
    }
}
