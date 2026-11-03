import SwiftUI
import KallilexKit
import KallilexUI

/// The Providers tab (ios-06): the list of `ProviderProfile`s, with a
/// privacy badge and the active marker, and entry points to add, edit, and
/// delete.
struct ProviderListView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var editingDraft: ProviderDraft?
    @State private var showPresetPicker = false
    @State private var profilePendingDelete: ProviderProfile?

    private var profiles: [ProviderProfile] { appEnv.settings.profiles }

    var body: some View {
        Group {
            if profiles.isEmpty {
                ContentUnavailableView {
                    Label(
                        String(localized: "tab.providers", defaultValue: "Providers"),
                        systemImage: "server.rack"
                    )
                } description: {
                    Text(String(
                        localized: "provider.empty.message",
                        defaultValue: "No providers yet. Tap Add to set one up."
                    ))
                }
                .accessibilityIdentifier("provider.emptyState")
            } else {
                List {
                    ForEach(profiles) { profile in
                        Button {
                            editingDraft = ProviderDraft(editing: profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(profile.name)
                                            .font(.body.weight(.semibold))
                                        if profile.id == appEnv.settings.activeProfileID {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                                .accessibilityIdentifier("provider.row.\(profile.id).active")
                                        }
                                    }
                                    PrivacyBadge(profile: profile, interactive: false)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .opacity(profile.enabled ? 1 : 0.5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("provider.row.\(profile.id)")
                        .swipeActions {
                            Button(role: .destructive) {
                                profilePendingDelete = profile
                            } label: {
                                Label(String(localized: "action.delete", defaultValue: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "tab.providers", defaultValue: "Providers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPresetPicker = true
                } label: {
                    Label(String(localized: "provider.add.button", defaultValue: "Add provider"), systemImage: "plus")
                }
                .accessibilityIdentifier("provider.add")
            }
        }
        .sheet(isPresented: $showPresetPicker) {
            ProviderPresetPickerView { draft in
                showPresetPicker = false
                editingDraft = draft
            }
        }
        .sheet(item: $editingDraft) { draft in
            ProviderEditor(draft: draft) { saved, apiKey in
                appEnv.perform { try $0.saveProfile(saved, apiKey: apiKey) }
            }
        }
        .alert(
            profilePendingDelete.map {
                String(localized: "provider.delete.confirm.title", defaultValue: "Delete \($0.name)?")
            } ?? "",
            isPresented: Binding(
                get: { profilePendingDelete != nil },
                set: { isPresented in if !isPresented { profilePendingDelete = nil } }
            )
        ) {
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "action.delete", defaultValue: "Delete"), role: .destructive) {
                if let profile = profilePendingDelete {
                    appEnv.perform { try $0.deleteProfile(id: profile.id) }
                }
            }
        } message: {
            if profilePendingDelete?.hasApiKey == true {
                Text(String(
                    localized: "provider.delete.confirm.keyWarning",
                    defaultValue: "The API key stored on this device will also be deleted."
                ))
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProviderListView()
    }
}
