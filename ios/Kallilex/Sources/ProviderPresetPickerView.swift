import SwiftUI
import KallilexKit

/// The "Add provider" sheet: a list of `providerPresets()`, each opening
/// the provider editor pre-filled with its defaults (ios-06). The on-device
/// preset is offered per `offeredProviderPresets` (ios-10): hidden on an
/// ineligible device, or once an on-device profile already exists.
struct ProviderPresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv
    let onSelect: (ProviderDraft) -> Void

    /// Starts out as if the device were ineligible, so the on-device
    /// preset never flashes into view before `.task` below resolves the
    /// real availability.
    @State private var onDeviceAvailability: OnDeviceAvailability = .deviceNotEligible

    private var presets: [ProviderPreset] {
        offeredProviderPresets(existingProfiles: appEnv.settings.profiles, onDeviceAvailability: onDeviceAvailability)
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
        .task {
            onDeviceAvailability = await appEnv.onDeviceModel.availability
        }
    }
}

#Preview {
    ProviderPresetPickerView { _ in }
}
