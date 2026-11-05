/// Builds the key rows for a layout/layer/globe combination. Pure data: no
/// drawing, no popups (ios-18 draws from this).
public struct KeyboardLayout: Sendable {
    /// `widthUnits` for the wide, non-letter keys shared by every row 4.
    private static let wideKeyWidth = 1.5
    /// `widthUnits` for a bare letter/digit/punctuation key.
    private static let regularKeyWidth = 1.0
    /// `widthUnits` for the space key when the globe key is also present.
    private static let spaceWidthWithGlobe = 5.0
    /// `widthUnits` for the space key when there is no globe key to share
    /// the row with (`showsGlobe == false` widens space by the globe's
    /// width).
    private static let spaceWidthWithoutGlobe = spaceWidthWithGlobe + regularKeyWidth

    /// Long-press alternates shared by both layouts, lower-case, each a
    /// single `Character`. Letters with no entry here (q, w, r, t, p, d, f,
    /// g, h, j, k, l, m, v, b, x) have no alternates.
    private static let letterAlternates: [Character: [String]] = [
        "a": ["ä", "à", "á", "â", "æ", "ã", "å"],
        "o": ["ö", "ò", "ó", "ô", "œ", "õ", "ø"],
        "u": ["ü", "ù", "ú", "û"],
        "s": ["ß"],
        "e": ["é", "è", "ê", "ë"],
        "i": ["î", "ï", "í", "ì"],
        "c": ["ç"],
        "n": ["ñ"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
    ]

    public static func rows(_ id: KeyboardLayoutID, layer: KeyboardLayer, showsGlobe: Bool) -> [[Key]] {
        switch layer {
        case .letters:
            return letterRows(id, showsGlobe: showsGlobe)
        case .numbers:
            return numberRows(id, showsGlobe: showsGlobe)
        case .symbols:
            return symbolRows(showsGlobe: showsGlobe)
        }
    }

    // MARK: - Letters

    private static func letterRows(_ id: KeyboardLayoutID, showsGlobe: Bool) -> [[Key]] {
        let row1Letters: [Character]
        let row2Letters: [Character]
        let row3Letters: [Character]
        switch id {
        case .qwertz:
            row1Letters = ["q", "w", "e", "r", "t", "z", "u", "i", "o", "p", "ü"]
            row2Letters = ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ö", "ä"]
            row3Letters = ["y", "x", "c", "v", "b", "n", "m"]
        case .qwerty:
            row1Letters = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
            row2Letters = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
            row3Letters = ["z", "x", "c", "v", "b", "n", "m"]
        }

        let row1 = row1Letters.map(letterKey)
        let row2 = row2Letters.map(letterKey)

        var row3: [Key] = [Key(kind: .shift, widthUnits: wideKeyWidth)]
        row3.append(contentsOf: row3Letters.map(letterKey))
        row3.append(Key(kind: .delete, widthUnits: wideKeyWidth))

        var row4: [Key] = [Key(kind: .layerSwitch(.numbers), widthUnits: wideKeyWidth)]
        appendGlobeAndSpace(to: &row4, showsGlobe: showsGlobe)
        row4.append(Key(kind: .character("."), widthUnits: regularKeyWidth))
        row4.append(Key(kind: .returnKey, widthUnits: wideKeyWidth))

        return [row1, row2, row3, row4]
    }

    private static func letterKey(_ letter: Character) -> Key {
        Key(kind: .character(String(letter)), alternates: letterAlternates[letter] ?? [], widthUnits: regularKeyWidth)
    }

    // MARK: - Numbers

    /// Modeled on the iOS system keyboard's numbers pad for the same
    /// language: digits, then `- / : ; ( ) <currency> & @ "`, then
    /// `#+= . , ? ! '` + delete, then `ABC` [globe] space return. The euro
    /// sign sits on QWERTZ's row, the dollar sign on QWERTY's; the other
    /// currency signs are long-press alternates on that key.
    private static func numberRows(_ id: KeyboardLayoutID, showsGlobe: Bool) -> [[Key]] {
        let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        let row1 = digits.map { Key(kind: .character(String($0)), widthUnits: regularKeyWidth) }

        let currencySymbol: String
        let currencyAlternates: [String]
        switch id {
        case .qwertz:
            currencySymbol = "€"
            currencyAlternates = ["$", "£", "¥", "¢"]
        case .qwerty:
            currencySymbol = "$"
            currencyAlternates = ["€", "£", "¥", "¢"]
        }

        let row2Symbols = ["-", "/", ":", ";", "(", ")", currencySymbol, "&", "@", "\""]
        let row2 = row2Symbols.map { symbol in
            Key(
                kind: .character(symbol),
                alternates: symbol == currencySymbol ? currencyAlternates : [],
                widthUnits: regularKeyWidth
            )
        }

        var row3: [Key] = [Key(kind: .layerSwitch(.symbols), widthUnits: wideKeyWidth)]
        row3.append(contentsOf: punctuationRow())
        row3.append(Key(kind: .delete, widthUnits: wideKeyWidth))

        var row4: [Key] = [Key(kind: .layerSwitch(.letters), widthUnits: wideKeyWidth)]
        appendGlobeAndSpace(to: &row4, showsGlobe: showsGlobe)
        row4.append(Key(kind: .returnKey, widthUnits: wideKeyWidth))

        return [row1, row2, row3, row4]
    }

    // MARK: - Symbols

    /// Modeled on the iOS system keyboard's symbols pad; identical for both
    /// layouts (only the numbers pad's currency key differs by language).
    private static func symbolRows(showsGlobe: Bool) -> [[Key]] {
        let row1Symbols = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
        let row1 = row1Symbols.map { Key(kind: .character($0), widthUnits: regularKeyWidth) }

        let row2Symbols = ["_", "\\", "|", "~", "<", ">", "€", "$", "•", "·"]
        let row2 = row2Symbols.map { Key(kind: .character($0), widthUnits: regularKeyWidth) }

        var row3: [Key] = [Key(kind: .layerSwitch(.numbers), widthUnits: wideKeyWidth)]
        row3.append(contentsOf: punctuationRow())
        row3.append(Key(kind: .delete, widthUnits: wideKeyWidth))

        var row4: [Key] = [Key(kind: .layerSwitch(.letters), widthUnits: wideKeyWidth)]
        appendGlobeAndSpace(to: &row4, showsGlobe: showsGlobe)
        row4.append(Key(kind: .returnKey, widthUnits: wideKeyWidth))

        return [row1, row2, row3, row4]
    }

    /// `. , ? ! '`, shared by the numbers and symbols row 3.
    private static func punctuationRow() -> [Key] {
        [".", ",", "?", "!", "'"].map { Key(kind: .character($0), widthUnits: regularKeyWidth) }
    }

    /// Appends the globe key (only when `showsGlobe`) and the space key
    /// (wider when there's no globe to share the row with) to a row 4
    /// that's still being built.
    private static func appendGlobeAndSpace(to row: inout [Key], showsGlobe: Bool) {
        if showsGlobe {
            row.append(Key(kind: .globe, widthUnits: regularKeyWidth))
        }
        row.append(Key(kind: .space, widthUnits: showsGlobe ? spaceWidthWithGlobe : spaceWidthWithoutGlobe))
    }
}
