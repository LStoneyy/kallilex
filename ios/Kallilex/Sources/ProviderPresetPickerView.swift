import SwiftUI
import KallilexKit

/// The "Add provider" sheet: a list of `providerPresets()`, each opening
/// the provider editor pre-filled with its defaults (ios-06). The on-device
/// preset is hidden until ios-10 adds an eligibility check.
struct ProviderPresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (ProviderDraft) -> Void

    private var presets: [ProviderPreset] {
        providerPresets().filter { $0.kind != .appleOnDevice }
    }

    var body: some View {
        NavigationStack {
            List(presets, id: \.id) { preset in
                Button {
                    onSelect(ProviderDraft(preset: preset))
                } label: {
                    Text(preset.label)
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("provider.preset.\(preset.id)")
            }
            .navigationTitle(String(localized: "provider.preset.picker.title", defaultValue: "Add Provider"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ProviderPresetPickerView { _ in }
}
