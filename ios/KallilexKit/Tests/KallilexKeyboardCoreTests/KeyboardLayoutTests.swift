import Testing
import KallilexKeyboardCore

/// `KeyboardLayout.rows`. See
/// `issues-ios/spec-ios-17-keyboard-core-layouts-state-routing.md`.
struct KeyboardLayoutTests {
    private func characters(_ row: [Key]) -> [String] {
        row.compactMap { key in
            if case .character(let base) = key.kind { return base }
            return nil
        }
    }

    // ---- letters ------------------------------------------------------

    @Test func qwertzLettersRowsHaveExpectedContent() {
        let rows = KeyboardLayout.rows(.qwertz, layer: .letters, showsGlobe: true)
        #expect(rows.count == 4)
        #expect(characters(rows[0]) == ["q", "w", "e", "r", "t", "z", "u", "i", "o", "p", "ü"])
        #expect(characters(rows[1]) == ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ö", "ä"])
        #expect(rows[2].first?.kind == .shift)
        #expect(characters(rows[2]) == ["y", "x", "c", "v", "b", "n", "m"])
        #expect(rows[2].last?.kind == .delete)
        #expect(rows[3].map(\.kind) == [
            .layerSwitch(.numbers), .globe, .space, .character("."), .returnKey,
        ])
    }

    @Test func qwertyLettersRowsHaveExpectedContent() {
        let rows = KeyboardLayout.rows(.qwerty, layer: .letters, showsGlobe: true)
        #expect(rows.count == 4)
        #expect(characters(rows[0]) == ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
        #expect(characters(rows[1]) == ["a", "s", "d", "f", "g", "h", "j", "k", "l"])
        #expect(rows[2].first?.kind == .shift)
        #expect(characters(rows[2]) == ["z", "x", "c", "v", "b", "n", "m"])
        #expect(rows[2].last?.kind == .delete)
        #expect(rows[3].map(\.kind) == [
            .layerSwitch(.numbers), .globe, .space, .character("."), .returnKey,
        ])
    }

    // ---- globe --------------------------------------------------------

    @Test(
        "the globe key is present only with showsGlobe, for every layout and layer",
        arguments: KeyboardLayoutID.allCases,
        [KeyboardLayer.letters, .numbers, .symbols]
    )
    func globeKeyPresentOnlyWithShowsGlobe(id: KeyboardLayoutID, layer: KeyboardLayer) {
        let withGlobe = KeyboardLayout.rows(id, layer: layer, showsGlobe: true).flatMap { $0 }
        let withoutGlobe = KeyboardLayout.rows(id, layer: layer, showsGlobe: false).flatMap { $0 }

        #expect(withGlobe.contains { $0.kind == .globe })
        #expect(!withoutGlobe.contains { $0.kind == .globe })

        // Without the globe key, space widens to take over its width.
        let spaceWithGlobe = withGlobe.first { $0.kind == .space }
        let spaceWithoutGlobe = withoutGlobe.first { $0.kind == .space }
        #expect(spaceWithoutGlobe?.widthUnits == (spaceWithGlobe?.widthUnits ?? 0) + 1.0)
    }

    // ---- alternates -----------------------------------------------------

    @Test(
        "every alternate, in every layout/layer combination, is a single lower-case Character",
        arguments: KeyboardLayoutID.allCases,
        [KeyboardLayer.letters, .numbers, .symbols]
    )
    func everyAlternateIsASingleLowerCaseCharacter(id: KeyboardLayoutID, layer: KeyboardLayer) {
        let keys = KeyboardLayout.rows(id, layer: layer, showsGlobe: true).flatMap { $0 }
        for key in keys {
            for alternate in key.alternates {
                #expect(alternate.count == 1, "\(alternate) in \(key) should be a single Character")
                #expect(alternate == alternate.lowercased(), "\(alternate) in \(key) should be lower-case")
            }
        }
    }

    @Test func yAndZAlternatesMatchTheSpec() {
        let qwertzLetters = KeyboardLayout.rows(.qwertz, layer: .letters, showsGlobe: true).flatMap { $0 }
        let yKey = qwertzLetters.first { $0.kind == .character("y") }
        let zKey = qwertzLetters.first { $0.kind == .character("z") }
        #expect(yKey?.alternates == ["ÿ"])
        // "z" is a dedicated letters-layer key only in QWERTY (QWERTZ has it
        // too, as row 1's "z"); check QWERTY's row 3 "z" directly.
        let qwertyLetters = KeyboardLayout.rows(.qwerty, layer: .letters, showsGlobe: true).flatMap { $0 }
        let zKeyQwerty = qwertyLetters.first { $0.kind == .character("z") }
        #expect(zKeyQwerty?.alternates == ["ž", "ź", "ż"])
        #expect(zKey?.alternates == ["ž", "ź", "ż"])
    }

    @Test func letterAlternatesCoverTheSpecifiedBaseLetters() {
        let keys = KeyboardLayout.rows(.qwertz, layer: .letters, showsGlobe: true).flatMap { $0 }
        func alternates(for base: String) -> [String] {
            keys.first { $0.kind == .character(base) }?.alternates ?? []
        }
        #expect(alternates(for: "a") == ["ä", "à", "á", "â", "æ", "ã", "å"])
        #expect(alternates(for: "o") == ["ö", "ò", "ó", "ô", "œ", "õ", "ø"])
        #expect(alternates(for: "u") == ["ü", "ù", "ú", "û"])
        #expect(alternates(for: "s") == ["ß"])
        #expect(alternates(for: "e") == ["é", "è", "ê", "ë"])
        #expect(alternates(for: "i") == ["î", "ï", "í", "ì"])
        #expect(alternates(for: "c") == ["ç"])
        #expect(alternates(for: "n") == ["ñ"])
    }

    // ---- numbers / symbols ----------------------------------------------

    @Test func qwertzNumbersLayerHasEuroWithOtherCurrenciesAsAlternates() {
        let keys = KeyboardLayout.rows(.qwertz, layer: .numbers, showsGlobe: true).flatMap { $0 }
        let euroKey = keys.first { $0.kind == .character("€") }
        #expect(euroKey != nil)
        #expect(euroKey?.alternates.contains("$") == true)
        #expect(!keys.contains { $0.kind == .character("$") })
    }

    @Test func qwertyNumbersLayerHasDollarWithOtherCurrenciesAsAlternates() {
        let keys = KeyboardLayout.rows(.qwerty, layer: .numbers, showsGlobe: true).flatMap { $0 }
        let dollarKey = keys.first { $0.kind == .character("$") }
        #expect(dollarKey != nil)
        #expect(dollarKey?.alternates.contains("€") == true)
        #expect(!keys.contains { $0.kind == .character("€") })
    }

    @Test func numbersRowOneIsTheTenDigits() {
        let rows = KeyboardLayout.rows(.qwerty, layer: .numbers, showsGlobe: true)
        #expect(characters(rows[0]) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    }

    @Test func symbolsLayerIsIdenticalAcrossLayouts() {
        let qwertz = KeyboardLayout.rows(.qwertz, layer: .symbols, showsGlobe: true)
        let qwerty = KeyboardLayout.rows(.qwerty, layer: .symbols, showsGlobe: true)
        #expect(qwertz == qwerty)
    }

    @Test func symbolsLayerRowOneMatchesTheSpecExample() {
        let rows = KeyboardLayout.rows(.qwertz, layer: .symbols, showsGlobe: true)
        #expect(characters(rows[0]) == ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])
    }

    // ---- layer-switch keys ------------------------------------------------

    @Test func layerSwitchKeysConnectAllThreeLayers() {
        let letters = KeyboardLayout.rows(.qwerty, layer: .letters, showsGlobe: true).flatMap { $0 }
        let numbers = KeyboardLayout.rows(.qwerty, layer: .numbers, showsGlobe: true).flatMap { $0 }
        let symbols = KeyboardLayout.rows(.qwerty, layer: .symbols, showsGlobe: true).flatMap { $0 }

        #expect(letters.contains { $0.kind == .layerSwitch(.numbers) })
        #expect(numbers.contains { $0.kind == .layerSwitch(.symbols) })
        #expect(numbers.contains { $0.kind == .layerSwitch(.letters) })
        #expect(symbols.contains { $0.kind == .layerSwitch(.numbers) })
        #expect(symbols.contains { $0.kind == .layerSwitch(.letters) })
    }
}
