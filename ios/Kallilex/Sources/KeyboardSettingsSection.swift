import SwiftUI
import KallilexKit
import KallilexUI

/// The Settings → Keyboard section (ios-22, `settings.keyboard`): the same
/// guide as onboarding's `.keyboardGuide` step, the layout picker, and a
/// test field to try the keyboard without leaving the app. Pulled out of
/// `SettingsView` into its own file since it's sizeable on its own, even
/// though the guide sheet it presents is actually owned (state and
/// `.sheet`) by `SettingsView`'s outer `Form` — see `showGuide`'s own doc
/// comment.
///
/// No status row and no Full Access row: there is no public API to detect
/// either the added keyboard or Full Access from the app (spike ios-01,
/// unknown 12 found only a private KVC key, which must not ship) — see
/// `KallilexUI.KeyboardGuideView`'s own doc comment.
struct KeyboardSettingsSection: View {
    @Environment(AppEnvironment.self) private var appEnv

    /// Owned by `SettingsView`, not by this type, and its `.sheet` lives
    /// there too, attached to the outer `Form` — see that call site's own
    /// comment for why a `Section` itself can't carry the presentation.
    @Binding var showGuide: Bool
    @State private var testText = ""

    /// Mirrors `KallilexKeyboardCore.KeyboardLayoutID`'s three choices
    /// without importing that target here: only `KallilexKit`/`KallilexUI`
    /// are linked by the app target, and `AppSettings.keyboardLayout` is
    /// itself a plain `String?` for the same reason (see that property's
    /// own doc comment in `Models.swift`). `rawStoredValue`/`init(stored:)`
    /// below are the one place this app-side mirror has to stay in sync
    /// with that enum's raw values ("qwertz"/"qwerty").
    private enum LayoutSelection: Hashable, CaseIterable, Identifiable {
        case automatic
        case qwertz
        case qwerty

        var id: Self { self }

        init(stored: String?) {
            switch stored {
            case "qwertz": self = .qwertz
            case "qwerty": self = .qwerty
            default: self = .automatic
            }
        }

        /// `nil` means "follow the device language" — written straight
        /// through to `AppSettings.keyboardLayout`.
        var rawStoredValue: String? {
            switch self {
            case .automatic: return nil
            case .qwertz: return "qwertz"
            case .qwerty: return "qwerty"
            }
        }

        var label: String {
            switch self {
            case .automatic:
                return String(localized: "settings.keyboard.layout.automatic", defaultValue: "Automatic")
            case .qwertz:
                return String(localized: "settings.keyboard.layout.qwertz", defaultValue: "QWERTZ (German)")
            case .qwerty:
                return String(localized: "settings.keyboard.layout.qwerty", defaultValue: "QWERTY (English)")
            }
        }
    }

    var body: some View {
        // Not `Section(String(...)) { ... }.accessibilityIdentifier(...)`:
        // a `.accessibilityIdentifier` applied to the whole `Section` in a
        // `Form` gets stamped onto every row generated from it, silently
        // overriding each row's own identifier (verified empirically —
        // ios-22's UI test failures before this fix, where every control
        // in this section reported identifier `settings.keyboard`). The
        // header `Text` below carries the section's own identifier
        // instead, since it's a single leaf view, not a repeated row.
        Section {
            Button {
                showGuide = true
            } label: {
                Text(String(localized: "settings.keyboard.guide", defaultValue: "How to add the keyboard"))
            }
            .accessibilityIdentifier("settings.keyboard.guide")

            Picker(
                String(localized: "settings.keyboard.layout.label", defaultValue: "Layout"),
                selection: layoutBinding
            ) {
                ForEach(LayoutSelection.allCases) { selection in
                    Text(selection.label).tag(selection)
                }
            }
            // `.menu`, not the Form default (a pushed list): keeps the
            // picker a single tap away, both for users and for XCUITest,
            // rather than a second screen to navigate back from.
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.keyboard.layout")

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "settings.keyboard.testField.label", defaultValue: "Try the keyboard"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "settings.keyboard.testField.hint", defaultValue: "Switch to Kallilex with 🌐"),
                    text: $testText,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .accessibilityIdentifier("settings.keyboard.testField")
            }
        } header: {
            Text(String(localized: "settings.keyboard.heading", defaultValue: "Keyboard"))
                .accessibilityIdentifier("settings.keyboard")
        }
    }

    /// Writes go straight through `AppEnvironment.updateSettings(_:)` —
    /// `SettingsService` has no dedicated operation for this flag, same as
    /// `autoRunFirstPrompt`/`autoCopyResult` elsewhere in `SettingsView`.
    private var layoutBinding: Binding<LayoutSelection> {
        Binding(
            get: { LayoutSelection(stored: appEnv.settings.keyboardLayout) },
            set: { newValue in
                appEnv.updateSettings { $0.keyboardLayout = newValue.rawStoredValue }
            }
        )
    }
}

#Preview {
    NavigationStack {
        Form {
            KeyboardSettingsSection(showGuide: .constant(false))
        }
    }
    .environment(AppEnvironment(
        settingsStore: InMemorySettingsStore(),
        secretStore: InMemorySecretStore(),
        actionRunner: ActionRunner(settings: InMemorySettingsStore(), secrets: InMemorySecretStore()),
        settings: .seeded()
    ))
}
