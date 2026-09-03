//
//  SettingsView.swift
//  Finance Wizard
//

import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var clientID: String = ""
    @State private var secret: String = ""
    @State private var environment: PlaidEnvironment = .sandbox
    @State private var redirectURI: String = ""
    @State private var didSave = false
    @State private var showSecret = false
    /// Relink must capture the Item here so the sheet doesn’t fall back to `.new`.
    @State private var linkSheetRequest: LinkSheetRequest?
    @State private var linkedItems: [PlaidLinkedItem] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var itemPendingDelete: PlaidLinkedItem?

    @State private var isExportingDebug = false
    @State private var debugExportURL: URL?
    @State private var showDebugShare = false
    @State private var showDebugExportConfirm = false

    @State private var showBackupPasswordSheet = false
    @State private var showRestorePasswordSheet = false
    @State private var showRestoreFilePicker = false
    @State private var showRestoreConfirm = false
    @State private var isWorkingPlaidBackup = false
    @State private var plaidBackupShareURL: URL?
    @State private var showPlaidBackupShare = false
    @State private var pendingRestoreURL: URL?
    @State private var pendingRestorePayload: PlaidConnectionBackup.Payload?
    @State private var showRestorePlanSheet = false
    @State private var restorePolicy: PlaidConnectionBackup.RestorePolicy = .safeMerge

    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Screenshot privacy
                Section {
                    Toggle(isOn: $screenshotPrivacy) {
                        Label("Hide for screenshots", systemImage: "eye.slash")
                    }
                } header: {
                    Text("Privacy")
                }

                // MARK: Credentials
                Section {
                    TextField("client_id", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    HStack {
                        Group {
                            if showSecret {
                                TextField("secret", text: $secret)
                            } else {
                                SecureField("secret", text: $secret)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    Picker("Environment", selection: $environment) {
                        ForEach(PlaidEnvironment.allCases) { env in
                            Text(env.displayName).tag(env)
                        }
                    }

                    TextField("OAuth redirect override", text: $redirectURI)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    Button("Save credentials") {
                        saveCredentials()
                    }

                    if didSave {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Plaid account")
                }

                // MARK: Linked banks
                Section {
                    if linkedItems.isEmpty {
                        Text("No banks linked yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedItems) { item in
                            HStack(spacing: 12) {
                                BankIconView(
                                    paymentMethod: item.institutionName,
                                    size: 36,
                                    displayName: item.institutionName,
                                    institutionName: item.institutionName
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.institutionName)
                                        .font(.body.weight(.semibold))
                                    if item.needsRelink {
                                        Text(item.errorMessage ?? "Login expired — Relink required")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    } else if !item.accountNames.isEmpty {
                                        Text(item.accountNames.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Linked \(item.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    startRelink(item)
                                } label: {
                                    Label("Relink…", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(!PlaidCredentialsStore.isConfigured)

                                Button(role: .destructive) {
                                    itemPendingDelete = item
                                } label: {
                                    Label("Unlink", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    startRelink(item)
                                } label: {
                                    Label("Relink", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.gray)
                                .disabled(!PlaidCredentialsStore.isConfigured)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    itemPendingDelete = item
                                } label: {
                                    Label("Unlink", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        linkSheetRequest = LinkSheetRequest(mode: .new)
                    } label: {
                        Label("Link bank account", systemImage: "plus.circle.fill")
                    }
                    .disabled(!PlaidCredentialsStore.isConfigured)
                } header: {
                    Text("Linked banks")
                }

                // MARK: Sync info
                Section {
                    LabeledContent("Credentials") {
                        Text(PlaidCredentialsStore.isConfigured ? "Configured" : "Missing")
                            .foregroundStyle(PlaidCredentialsStore.isConfigured ? .green : .orange)
                    }
                    LabeledContent("Environment") {
                        Text(PlaidCredentialsStore.environment.displayName)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Linked items") {
                        Text("\(linkedItems.count)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status")
                }

                // MARK: Full backup
                Section {
                    Button {
                        showBackupPasswordSheet = true
                    } label: {
                        if isWorkingPlaidBackup {
                            HStack {
                                ProgressView()
                                Text("Working…")
                            }
                        } else {
                            Label("Back up everything", systemImage: "lock.shield")
                        }
                    }
                    .disabled(isWorkingPlaidBackup)

                    Button {
                        showRestoreConfirm = true
                    } label: {
                        Label("Restore from backup", systemImage: "arrow.counterclockwise.circle")
                    }
                    .disabled(isWorkingPlaidBackup)
                } header: {
                    Text("Backup & restore")
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .secondary)
                    }
                }

                // MARK: About
                Section {
                    NavigationLink {
                        AboutBuildView()
                    } label: {
                        HStack {
                            Text("About")
                            Spacer()
                            Text(AppBuildInfo.versionBuildLabel)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        showDebugExportConfirm = true
                    } label: {
                        if isExportingDebug {
                            HStack {
                                ProgressView()
                                Text("Preparing export…")
                            }
                        } else {
                            Label("Export database for debug", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExportingDebug)
                } header: {
                    Text("About")
                }
                
                Section {
                    OnDeviceAIStatusView()
                } header: {
                    Text("On-device AI")
                }

                Section {
                    NavigationLink {
                        DebugMenuView()
                    } label: {
                        Label("Debug", systemImage: "ant")
                    }
                } header: {
                    Text("Developer")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                reload()
                consumeIncomingBackupIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: PlaidConnectionBackup.openFileNotification)) { _ in
                consumeIncomingBackupIfNeeded()
            }
            .sheet(item: $linkSheetRequest, onDismiss: reload) { request in
                PlaidLinkSheet(mode: request.mode) { result in
                    switch result {
                    case .success(let item):
                        statusIsError = false
                        switch request.mode {
                        case .new:
                            statusMessage = "Linked \(item.institutionName). Tap Sync on Transactions."
                            Task { await reconcileAfterRelink(item) }
                        case .update:
                            statusMessage = "Relinked \(item.institutionName). Refreshing accounts…"
                            Task { await reconcileAfterRelink(item) }
                        }
                    case .failure(let error):
                        statusIsError = true
                        statusMessage = error.localizedDescription
                    }
                    reload()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .plaidItemsReplaced)) { note in
                let ids = (note.userInfo?["itemIds"] as? [String]) ?? []
                guard !ids.isEmpty else { return }
                let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
                for account in all where ids.contains(account.itemId) {
                    modelContext.delete(account)
                }
                try? modelContext.save()
                reload()
            }
            .confirmationDialog(
                "Unlink \(itemPendingDelete?.institutionName ?? "bank")?",
                isPresented: Binding(
                    get: { itemPendingDelete != nil },
                    set: { if !$0 { itemPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Unlink", role: .destructive) {
                    if let item = itemPendingDelete {
                        unlink(item)
                    }
                    itemPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    itemPendingDelete = nil
                }
            } message: {
                Text("Unlinks this bank from Finance Wizard. You can also remove it from your Plaid account.")
            }
            .confirmationDialog(
                "Export debug data?",
                isPresented: $showDebugExportConfirm,
                titleVisibility: .visible
            ) {
                Button("Export & Share") {
                    Task { await runDebugExport() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shares a local copy of your data for troubleshooting. Secrets and bank login tokens are not included.")
            }
            .confirmationDialog(
                "Restore from backup?",
                isPresented: $showRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Choose backup file…") {
                    showRestoreFilePicker = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You’ll enter the backup password, then review a restore plan. Safe merge never overwrites access tokens already on this phone. Wipe device, then restore deletes local data first so the backup is the only copy.")
            }
            .sheet(isPresented: $showDebugShare, onDismiss: {
                debugExportURL = nil
            }) {
                if let debugExportURL {
                    ShareSheet(items: [debugExportURL]) {
                        showDebugShare = false
                    }
                }
            }
            .sheet(isPresented: $showPlaidBackupShare, onDismiss: {
                plaidBackupShareURL = nil
            }) {
                if let plaidBackupShareURL {
                    ShareSheet(items: [plaidBackupShareURL]) {
                        showPlaidBackupShare = false
                    }
                }
            }
            .sheet(isPresented: $showBackupPasswordSheet) {
                PlaidBackupPasswordSheet(
                    mode: .createBackup,
                    isWorking: $isWorkingPlaidBackup
                ) { password in
                    try await runPlaidBackup(password: password)
                }
            }
            .sheet(isPresented: $showRestorePasswordSheet, onDismiss: {
                // Drop the security-scoped file if the user cancelled without decrypting.
                if !isWorkingPlaidBackup && pendingRestorePayload == nil {
                    pendingRestoreURL = nil
                }
            }) {
                PlaidBackupPasswordSheet(
                    mode: .restore,
                    isWorking: $isWorkingPlaidBackup
                ) { password in
                    try await decryptRestorePayload(password: password)
                }
            }
            .sheet(isPresented: $showRestorePlanSheet, onDismiss: {
                if !isWorkingPlaidBackup {
                    pendingRestorePayload = nil
                    pendingRestoreURL = nil
                    restorePolicy = .safeMerge
                }
            }) {
                if let payload = pendingRestorePayload {
                    PlaidRestorePlanSheet(
                        payload: payload,
                        policy: $restorePolicy,
                        isWorking: $isWorkingPlaidBackup
                    ) {
                        try await applyRestorePayload()
                    }
                }
            }
            .fileImporter(
                isPresented: $showRestoreFilePicker,
                allowedContentTypes: Self.plaidBackupContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    pendingRestoreURL = url
                    pendingRestorePayload = nil
                    restorePolicy = .safeMerge
                    showRestorePasswordSheet = true
                case .failure(let error):
                    statusIsError = true
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    /// UTTypes accepted by the restore file picker.
    private static var plaidBackupContentTypes: [UTType] {
        PlaidConnectionBackup.importContentTypes
    }

    /// Start restore when a `.fwbackup` was opened from Files / another app.
    private func consumeIncomingBackupIfNeeded() {
        if let error = AppBackupOpenBridge.pendingError {
            AppBackupOpenBridge.pendingError = nil
            statusIsError = true
            statusMessage = error
            return
        }
        guard let url = AppBackupOpenBridge.pendingURL else { return }
        AppBackupOpenBridge.pendingURL = nil
        pendingRestoreURL = url
        pendingRestorePayload = nil
        restorePolicy = .safeMerge
        showRestorePasswordSheet = true
        statusIsError = false
        statusMessage = "Opened \(url.lastPathComponent). Enter the backup password to continue."
    }

    @MainActor
    private func runDebugExport() async {
        isExportingDebug = true
        statusMessage = nil
        defer { isExportingDebug = false }
        do {
            let url = try DebugDataExporter.exportPackage(modelContext: modelContext)
            debugExportURL = url
            showDebugShare = true
            statusIsError = false
            statusMessage = "Debug export ready: \(url.lastPathComponent)"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    /// Encrypt full app state and present the system share sheet.
    @MainActor
    private func runPlaidBackup(password: String) async throws {
        isWorkingPlaidBackup = true
        defer { isWorkingPlaidBackup = false }
        // Yield once so the sheet can paint the ProgressView before PBKDF2 runs.
        await Task.yield()
        let url = try PlaidConnectionBackup.exportEncryptedFile(
            password: password,
            modelContext: modelContext
        )
        plaidBackupShareURL = url
        showPlaidBackupShare = true
        statusIsError = false
        let banks = PlaidItemStore.loadItems().count
        statusMessage = "Encrypted full backup ready (\(banks) bank connection\(banks == 1 ? "" : "s") + local data). Save it somewhere safe."
        reload()
    }

    /// Decrypt only — shows the Safe merge plan before any writes.
    @MainActor
    private func decryptRestorePayload(password: String) async throws {
        guard let url = pendingRestoreURL else {
            throw PlaidConnectionBackup.BackupError.invalidFile
        }
        isWorkingPlaidBackup = true
        defer { isWorkingPlaidBackup = false }
        await Task.yield()
        let payload = try PlaidConnectionBackup.decryptPayload(from: url, password: password)
        pendingRestorePayload = payload
        restorePolicy = .safeMerge
        showRestorePlanSheet = true
    }

    /// Apply the decrypted payload with the chosen policy.
    @MainActor
    private func applyRestorePayload() async throws {
        guard let payload = pendingRestorePayload else {
            throw PlaidConnectionBackup.BackupError.invalidFile
        }
        isWorkingPlaidBackup = true
        defer {
            isWorkingPlaidBackup = false
            pendingRestorePayload = nil
            pendingRestoreURL = nil
        }
        await Task.yield()
        let summary = try PlaidConnectionBackup.apply(
            payload: payload,
            policy: restorePolicy,
            modelContext: modelContext
        )
        reload()
        clientID = PlaidCredentialsStore.clientID
        secret = PlaidCredentialsStore.secret
        environment = PlaidCredentialsStore.environment
        redirectURI = PlaidCredentialsStore.redirectURI
        statusIsError = false
        statusMessage = restoreStatusMessage(summary)
    }

    private func restoreStatusMessage(_ summary: PlaidConnectionBackup.RestoreSummary) -> String {
        var parts: [String] = []
        if summary.itemsAdded > 0 {
            let names = summary.institutionNamesAdded.isEmpty
                ? "\(summary.itemsAdded) bank(s)"
                : summary.institutionNamesAdded.joined(separator: ", ")
            parts.append("added \(names)")
        }
        if summary.itemsPreserved > 0 {
            parts.append("kept \(summary.itemsPreserved) existing token(s)")
        }
        if summary.itemsTokenReplaced > 0 {
            parts.append("replaced \(summary.itemsTokenReplaced) token(s)")
        }
        if summary.credentialsWritten {
            parts.append("API keys written")
        } else if summary.credentialsSkipped {
            parts.append("API keys left unchanged")
        }
        if summary.transactionsUpserted > 0 {
            parts.append("\(summary.transactionsUpserted) transactions")
        }
        if summary.incomeUpserted > 0 {
            parts.append("\(summary.incomeUpserted) income")
        }
        if summary.bankAccountsUpserted > 0 {
            parts.append("\(summary.bankAccountsUpserted) accounts")
        }
        if summary.payoffPlansUpserted > 0 {
            parts.append("\(summary.payoffPlansUpserted) payoff plans")
        }
        let detail = parts.isEmpty ? "nothing new to apply" : parts.joined(separator: " · ")
        let policyLabel: String = {
            switch summary.policy {
            case .safeMerge: return "safe merge"
            case .replaceConnections: return "replace"
            case .wipeThenRestore: return "wipe then restore"
            }
        }()
        return "Restore complete (\(policyLabel)): \(detail). \(summary.environment). Tap Sync if needed."
    }

    /// Reloads credentials and linked banks from stores into local @State for the form.
    private func reload() {
        clientID = PlaidCredentialsStore.clientID
        secret = PlaidCredentialsStore.secret
        environment = PlaidCredentialsStore.environment
        // Drop legacy localhost OAuth redirect (not a valid Plaid allowlist target)
        PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
        redirectURI = PlaidCredentialsStore.redirectURI
        linkedItems = PlaidItemStore.loadItems()
        // One-shot cleanup of BankAccounts left behind by old Relink/Unlink bugs
        let removed = PlaidSyncEngine.cleanupStaleBankAccounts(modelContext: modelContext)
        if removed > 0 {
            try? modelContext.save()
        }
    }

    /// Writes the form fields into PlaidCredentialsStore (device-local storage).
    private func saveCredentials() {
        PlaidCredentialsStore.clientID = clientID
        PlaidCredentialsStore.secret = secret
        PlaidCredentialsStore.environment = environment
        let trimmedRedirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        // Plaid only allows https:// redirect URIs in the dashboard allowlist.
        if !trimmedRedirect.isEmpty, !trimmedRedirect.lowercased().hasPrefix("https://") {
            statusIsError = true
            statusMessage = "OAuth redirect must start with https:// (Plaid does not allow custom schemes there)."
            return
        }
        PlaidCredentialsStore.redirectURI = trimmedRedirect
        PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
        redirectURI = PlaidCredentialsStore.redirectURI
        didSave = true
        statusIsError = false
        statusMessage = "Credentials saved on this device."
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSave = false
        }
    }

    /// Opens Plaid Link in update mode for an existing linked Item (relink / re-auth).
    private func startRelink(_ item: PlaidLinkedItem) {
        guard PlaidCredentialsStore.isConfigured else {
            statusIsError = true
            statusMessage = "Add Plaid credentials before relinking."
            return
        }
        linkSheetRequest = LinkSheetRequest(mode: .update(item))
    }

    /// Pull live accounts after update-mode Link and drop deselected ones from SwiftData.
    @MainActor
    private func reconcileAfterRelink(_ item: PlaidLinkedItem) async {
        PlaidItemStore.clearItemError(itemID: item.id)
        do {
            let n = try await PlaidSyncEngine.reconcileItemAccounts(
                item: item,
                modelContext: modelContext
            )
            try? modelContext.save()
            statusIsError = false
            statusMessage = "Relinked \(item.institutionName) · \(n) account(s). Tap Sync for transactions."
            reload()
        } catch {
            statusIsError = true
            statusMessage = "Relinked, but account refresh failed: \(error.localizedDescription). Tap Sync."
            reload()
        }
    }

    /// Removes a bank remotely (best-effort) and deletes local rows + Plaid Item metadata.
    private func unlink(_ item: PlaidLinkedItem) {
        Task {
            // Best-effort remote remove
            try? await PlaidAPIClient.removeItem(accessToken: item.accessToken)
            // Hop back to the main actor before touching UI state / SwiftData UI models.
            await MainActor.run {
                // Remove local bank rows for this Item so they don’t linger after unlink
                let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
                for account in all where account.itemId == item.id {
                    modelContext.delete(account)
                }
                try? modelContext.save()
                PlaidItemStore.remove(itemID: item.id)
                reload()
                statusIsError = false
                statusMessage = "Unlinked \(item.institutionName)."
            }
        }
    }
}

// MARK: - Link sheet request (stable mode capture)

/// Identifiable wrapper so `.sheet(item:)` can present Plaid Link with a fixed mode.
/// Capturing mode on a struct avoids racey re-reads of separate @State flags.
private struct LinkSheetRequest: Identifiable {
    let id = UUID()
    let mode: PlaidLinkMode
}

// MARK: - Plaid backup password sheet

/// Collects a password for encrypting or decrypting a full app backup.
private struct PlaidBackupPasswordSheet: View {
    enum Mode {
        case createBackup
        case restore
    }

    let mode: Mode
    @Binding var isWorking: Bool
    /// Async work that throws; sheet dismisses only on success.
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var showPassword = false

    private var title: String {
        switch mode {
        case .createBackup: return "Back up everything"
        case .restore: return "Unlock backup"
        }
    }

    private var canSubmit: Bool {
        let min = PlaidConnectionBackup.minimumPasswordLength
        guard password.count >= min else { return false }
        if mode == .createBackup {
            return password == confirmPassword
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(mode == .createBackup ? .newPassword : .password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if mode == .createBackup {
                        Group {
                            if showPassword {
                                TextField("Confirm password", text: $confirmPassword)
                            } else {
                                SecureField("Confirm password", text: $confirmPassword)
                            }
                        }
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    Toggle("Show password", isOn: $showPassword)
                } header: {
                    Text("Password")
                }

                if mode == .createBackup, !confirmPassword.isEmpty, password != confirmPassword {
                    Section {
                        Text("Passwords do not match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(mode == .createBackup ? "Create" : "Continue") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func submit() async {
        errorMessage = nil
        guard canSubmit else { return }
        do {
            try await onSubmit(password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Restore plan (review before writes)

/// Shows a dry-run of restore impact and policy before any Keychain / data writes.
private struct PlaidRestorePlanSheet: View {
    let payload: PlaidConnectionBackup.Payload
    @Binding var policy: PlaidConnectionBackup.RestorePolicy
    @Binding var isWorking: Bool
    let onConfirm: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var plan: PlaidConnectionBackup.RestorePlan {
        PlaidConnectionBackup.planRestore(payload: payload, policy: policy)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Policy", selection: $policy) {
                        ForEach(PlaidConnectionBackup.RestorePolicy.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(policy.detail)
                        .font(.caption)
                        .foregroundStyle(policy.wipesLocalData ? .orange : .secondary)
                } header: {
                    Text("How to restore")
                }

                Section {
                    LabeledContent("API keys") {
                        Text(plan.credentialsAction)
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    if !plan.itemsToAdd.isEmpty {
                        LabeledContent("Banks to add") {
                            Text(plan.itemsToAdd.joined(separator: ", "))
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.green)
                        }
                    }
                    if !plan.itemsPreserved.isEmpty {
                        LabeledContent("Tokens kept (untouched)") {
                            Text(plan.itemsPreserved.joined(separator: ", "))
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !plan.itemsTokenReplaced.isEmpty {
                        LabeledContent("Tokens to replace") {
                            Text(plan.itemsTokenReplaced.joined(separator: ", "))
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.orange)
                        }
                    }
                    if plan.itemsToAdd.isEmpty && plan.itemsPreserved.isEmpty && plan.itemsTokenReplaced.isEmpty {
                        Text("No bank connections in this backup.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connections")
                }

                Section {
                    LabeledContent("Transactions", value: "\(plan.transactionCount)")
                    LabeledContent("Income", value: "\(plan.incomeCount)")
                    LabeledContent("Accounts", value: "\(plan.bankAccountCount)")
                    LabeledContent("Card payments", value: "\(plan.paymentCount)")
                    LabeledContent("Budget plans", value: "\(plan.budgetPlanCount)")
                    LabeledContent("Payoff plans", value: "\(plan.payoffPlanCount)")
                    LabeledContent("Nicknames", value: "\(plan.cardLabelCount)")
                    LabeledContent("Vendor rules", value: "\(plan.vendorRuleCount)")
                } header: {
                    Text(policy.wipesLocalData ? "App data (replace)" : "App data (upsert)")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(policy.wipesLocalData ? "Wipe & Restore" : "Restore") {
                            Task { await confirm() }
                        }
                        .foregroundStyle(policy.wipesLocalData ? .red : .accentColor)
                    }
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    @MainActor
    private func confirm() async {
        errorMessage = nil
        do {
            try await onConfirm()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Build info (from Info.plist / Xcode versions)

/// Reads marketing version, build number, and related values from the app’s Info.plist.
enum AppBuildInfo {
    /// CFBundleShortVersionString ← MARKETING_VERSION (e.g. 1.0)
    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// CFBundleVersion ← CURRENT_PROJECT_VERSION (e.g. 5)
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// Combined label like "1.0 (1)" for display in Settings.
    static var versionBuildLabel: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Finance Wizard"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "—"
    }

    static var minimumOS: String {
        Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
            ?? "—"
    }
}

/// Detail screen showing app version, bundle id, and device runtime info.
struct AboutBuildView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("App") {
                    Text(AppBuildInfo.displayName)
                }
                LabeledContent("Version") {
                    Text(AppBuildInfo.marketingVersion)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Build") {
                    Text(AppBuildInfo.buildNumber)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Version (build)") {
                    Text(AppBuildInfo.versionBuildLabel)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Release")
            }

            Section("Identifiers") {
                LabeledContent("Bundle ID") {
                    Text(AppBuildInfo.bundleIdentifier)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Minimum iOS") {
                    Text(AppBuildInfo.minimumOS)
                        .font(.body.monospaced())
                }
            }

            Section("Runtime") {
                LabeledContent("iOS") {
                    Text(UIDevice.current.systemVersion)
                        .font(.body.monospaced())
                }
                LabeledContent("Device") {
                    Text(UIDevice.current.model)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
}
