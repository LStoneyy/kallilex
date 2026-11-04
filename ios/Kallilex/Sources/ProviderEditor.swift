import SwiftUI
import KallilexKit

/// Result of the most recent "Test connection" attempt, shown inline below
/// the button (ios-06).
private enum ProviderTestState: Equatable {
    case idle
    case running
    case success
    case failure(String)
}

/// The Add/Edit sheet for a single provider profile (ios-06). Owns a
/// `ProviderDraft`; nothing is persisted until Save is tapped — Cancel (or
/// dismissing the sheet) discards every change, including any API-key
/// replace/remove.
struct ProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv

    @State private var draft: ProviderDraft
    @State private var isEditingApiKey = false
    @State private var testState: ProviderTestState = .idle
    @State private var testTask: Task<Void, Never>?
    /// `nil` until the `.task` in `availabilitySection` resolves (ios-10) —
    /// shows a transient "Checking…" row rather than a wrong answer.
    @State private var onDeviceAvailability: OnDeviceAvailability?

    // Suppresses validation messages until the user has actually edited
    // the corresponding field: opening a blank "Add provider" form
    // shouldn't greet the user with "Model is required." before they've
    // typed anything. Save stays disabled the whole time regardless
    // (`draft.canSave`) — these flags only control when the *message*
    // appears, not whether Save is enabled.
    @State private var nameTouched = false
    @State private var baseUrlTouched = false
    @State private var modelTouched = false

    let onSave: (ProviderProfile, String?) -> Void

    init(draft: ProviderDraft, onSave: @escaping (ProviderProfile, String?) -> Void) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
        // Editing an already-saved profile: there's existing data in every
        // field, so there's nothing to hide — show validation immediately
        // if it's somehow invalid. Only a brand-new draft (blank `id`)
        // starts with messages suppressed.
        let editingExisting = !draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self._nameTouched = State(initialValue: editingExisting)
        self._baseUrlTouched = State(initialValue: editingExisting)
        self._modelTouched = State(initialValue: editingExisting)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "provider.name.label", defaultValue: "Name")) {
                        TextField(
                            String(localized: "provider.name.placeholder", defaultValue: "Name"),
                            text: $draft.name
                        )
                        .accessibilityIdentifier("provider.editor.name")
                    }
                    if nameTouched, draft.validationErrors.contains(.blankName) {
                        Text(ProviderDraftValidationError.blankName.errorDescription ?? "")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .onChange(of: draft.name) { _, _ in nameTouched = true }

                switch draft.kind {
                case .unknown:
                    unknownKindSection
                case .appleOnDevice:
                    availabilitySection
                case .openAICompatible:
                    baseUrlAndModelSection
                    apiKeySection
                    timeoutSection
                    customHeadersSection
                }

                Section {
                    Toggle(
                        String(localized: "provider.enabled", defaultValue: "Enabled"),
                        isOn: $draft.enabled
                    )
                    .accessibilityIdentifier("provider.editor.enabled")
                }

                Section {
                    Button(String(localized: "provider.setActive", defaultValue: "Use this provider")) {
                        appEnv.perform { try $0.setActiveProfile(id: draft.id) }
                    }
                    .disabled(!draft.canActivate)
                    .accessibilityIdentifier("provider.editor.setActive")

                    testConnectionRow
                }
            }
            .navigationTitle(draft.name.isEmpty
                ? String(localized: "provider.preset.picker.title", defaultValue: "Add Provider")
                : draft.name
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("provider.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save", defaultValue: "Save")) {
                        onSave(draft.makeProfile(), draft.apiKeyArgument)
                        dismiss()
                    }
                    .disabled(!draft.canSave)
                    .accessibilityIdentifier("provider.editor.save")
                }
            }
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    // MARK: - Sections

    private var unknownKindSection: some View {
        Section {
            Text(String(
                localized: "provider.unknownKind.notice",
                defaultValue: "This provider type isn't supported by this version of Kallilex."
            ))
            .foregroundStyle(.secondary)
        }
    }

    /// Read-only availability status for an `.appleOnDevice` profile
    /// (ios-10): "Ready" when available, else the reason and a hint —
    /// `OnDeviceAvailability.statusText` already composes both into one
    /// sentence. Loaded asynchronously so switching into this section never
    /// blocks the sheet from appearing.
    private var availabilitySection: some View {
        Section(String(localized: "provider.availability", defaultValue: "Availability")) {
            Text(onDeviceAvailability?.statusText ?? String(
                localized: "provider.availability.checking",
                defaultValue: "Checking…"
            ))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("provider.editor.availability")
        }
        .task {
            onDeviceAvailability = await appEnv.onDeviceModel.availability
        }
    }

    private var baseUrlAndModelSection: some View {
        Section {
            LabeledContent(String(localized: "provider.baseUrl.label", defaultValue: "Base URL")) {
                TextField(
                    String(localized: "provider.baseUrl.placeholder", defaultValue: "https://api.example.com/v1"),
                    text: $draft.baseUrl
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("provider.editor.baseUrl")
            }
            .onChange(of: draft.baseUrl) { _, _ in baseUrlTouched = true }
            if baseUrlTouched, draft.validationErrors.contains(.invalidBaseUrl) {
                Text(ProviderDraftValidationError.invalidBaseUrl.errorDescription ?? "")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LabeledContent(String(localized: "provider.model.label", defaultValue: "Model")) {
                TextField(
                    String(localized: "provider.model.placeholder", defaultValue: "gpt-4-turbo"),
                    text: $draft.model
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("provider.editor.model")
            }
            .onChange(of: draft.model) { _, _ in modelTouched = true }
            if modelTouched, draft.validationErrors.contains(.blankModel) {
                Text(ProviderDraftValidationError.blankModel.errorDescription ?? "")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(draft.warnings, id: \.self) { warning in
                Text(warning.errorDescription ?? "")
                    .font(.caption)
                    .foregroundStyle(warning == .insecureHttpToCloud ? .red : .secondary)
                    .accessibilityIdentifier(
                        warning == .insecureHttpToCloud
                            ? "provider.editor.warning.insecureUrl"
                            : "provider.editor.hint.localNetwork"
                    )
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            if effectiveHasApiKey, !isEditingApiKey {
                Text(String(
                    localized: "provider.apiKey.saved",
                    defaultValue: "API key saved on this device"
                ))
                .accessibilityIdentifier("provider.editor.apiKey.saved")
                HStack {
                    Button(String(localized: "provider.apiKey.replace", defaultValue: "Replace")) {
                        draft.apiKeyIntent = .replace("")
                        isEditingApiKey = true
                    }
                    .accessibilityIdentifier("provider.editor.apiKey.replace")
                    Spacer()
                    Button(String(localized: "provider.apiKey.remove", defaultValue: "Remove"), role: .destructive) {
                        draft.apiKeyIntent = .remove
                        isEditingApiKey = false
                    }
                    .accessibilityIdentifier("provider.editor.apiKey.remove")
                }
            } else if isEditingApiKey {
                SecureField(
                    String(localized: "provider.apiKey.placeholder", defaultValue: "Paste your API key"),
                    text: apiKeyFieldBinding
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Kallilex stores this key itself (Keychain, via
                // `SecretStore`) — without this, iOS treats a bare
                // `SecureField` as a login password and offers its own
                // "Save Password?" prompt after Save, which then sits on
                // top of the app and blocks every subsequent interaction.
                .textContentType(.oneTimeCode)
                .accessibilityIdentifier("provider.editor.apiKey.field")
            } else {
                Button(String(localized: "provider.apiKey.pasteAndSave", defaultValue: "Paste and save")) {
                    draft.apiKeyIntent = .replace("")
                    isEditingApiKey = true
                }
                .accessibilityIdentifier("provider.editor.apiKey.pasteAndSave")
            }
        }
    }

    private var timeoutSection: some View {
        Section {
            Stepper(value: $draft.timeoutSecs, in: ProviderDraft.timeoutRange) {
                HStack {
                    Text(String(localized: "provider.timeout", defaultValue: "Request timeout (s)"))
                    Spacer()
                    Text("\(draft.timeoutSecs)")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("provider.editor.timeout")
        }
    }

    private var customHeadersSection: some View {
        Section(String(localized: "provider.customHeaders.title", defaultValue: "Custom Headers")) {
            ForEach(draft.customHeaders.indices, id: \.self) { index in
                HStack {
                    TextField(
                        String(localized: "provider.customHeaders.name.placeholder", defaultValue: "Header name"),
                        text: Binding(
                            get: { draft.customHeaders[index].name },
                            set: { draft.customHeaders[index] = HeaderEntry(name: $0, value: draft.customHeaders[index].value) }
                        )
                    )
                    .accessibilityIdentifier("provider.editor.header.name.\(index)")
                    TextField(
                        String(localized: "provider.customHeaders.value.placeholder", defaultValue: "Header value"),
                        text: Binding(
                            get: { draft.customHeaders[index].value },
                            set: { draft.customHeaders[index] = HeaderEntry(name: draft.customHeaders[index].name, value: $0) }
                        )
                    )
                    .accessibilityIdentifier("provider.editor.header.value.\(index)")
                }
            }
            .onDelete { offsets in draft.customHeaders.remove(atOffsets: offsets) }

            Button {
                draft.customHeaders.append(HeaderEntry(name: "", value: ""))
            } label: {
                Label(String(localized: "provider.customHeaders.add", defaultValue: "Add header"), systemImage: "plus")
            }
            .accessibilityIdentifier("provider.editor.headers.add")
        }
    }

    private var testConnectionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if draft.testConnectionKeySource() == .storedKeyWithheld {
                Text(String(
                    localized: "provider.apiKey.withheldForTest",
                    defaultValue: "The saved API key is only sent to \(draft.originalHost ?? "the original address"). Replace it to test the new address."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("provider.editor.apiKey.withheldForTest")
            }

            Button(String(localized: "provider.testConnection", defaultValue: "Test connection")) {
                runTestConnection()
            }
            .disabled(testState == .running)
            .accessibilityIdentifier("provider.editor.testConnection")

            switch testState {
            case .idle:
                EmptyView()
            case .running:
                ProgressView()
                    .accessibilityIdentifier("provider.editor.testConnection.progress")
            case .success:
                Text(String(
                    localized: "provider.testConnection.success",
                    defaultValue: "✓ Connection successful"
                ))
                .foregroundStyle(.green)
                .accessibilityIdentifier("provider.editor.testConnection.result")
            case .failure(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("provider.editor.testConnection.result")
            }
        }
    }

    // MARK: - Helpers

    private var effectiveHasApiKey: Bool {
        switch draft.apiKeyIntent {
        case .remove: return false
        case .replace: return true
        case .keep: return draft.hasApiKeyStored
        }
    }

    private var apiKeyFieldBinding: Binding<String> {
        Binding(
            get: {
                if case .replace(let key) = draft.apiKeyIntent { return key }
                return ""
            },
            set: { draft.apiKeyIntent = .replace($0) }
        )
    }

    private func resolveApiKeyForTest() -> String? {
        switch draft.testConnectionKeySource() {
        case .none, .storedKeyWithheld:
            return nil
        case .draftKey(let key):
            return key
        case .storedKey:
            return try? appEnv.secretStore.get(profileID: draft.id)
        }
    }

    private func runTestConnection() {
        testTask?.cancel()
        testState = .running
        let profile = draft.makeProfile()
        let apiKey = resolveApiKeyForTest()
        testTask = Task {
            let result = await appEnv.actionRunner.testConnection(profile: profile, apiKey: apiKey)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                testState = .success
            case .failure(let error):
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

#Preview {
    ProviderEditor(draft: ProviderDraft(preset: providerPresets()[1])) { _, _ in }
}
