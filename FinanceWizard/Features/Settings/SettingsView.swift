//
//  SettingsView.swift
//  Finance Wizard
//
//  Settings screen: Plaid developer credentials, linked banks, status, and debug export.
//  Built with SwiftUI (declarative UI — you describe what the screen should look like;
//  SwiftUI updates it when @State / data changes).
//

import SwiftUI
import SwiftData
import UIKit

/// Main Settings screen for Plaid keys, bank links, privacy, and About.
///
/// `struct …: View` means this type conforms to the View protocol — it must provide a
/// `body` that returns UI. SwiftUI re-evaluates `body` when observed state changes.
struct SettingsView: View {
    // @Environment reads a value from the SwiftUI environment (shared down the view tree).
    // modelContext is the SwiftData “scratchpad” for insert/update/delete/save of model objects.
    @Environment(\.modelContext) private var modelContext

    // @State stores view-owned mutable data. Changing it triggers a UI refresh.
    // private keeps these properties only usable inside this type.
    @State private var clientID: String = ""
    @State private var secret: String = ""
    @State private var environment: PlaidEnvironment = .sandbox
    @State private var redirectURI: String = ""
    @State private var didSave = false
    @State private var showSecret = false
    /// Sheet payload so Relink always passes the correct Item (avoids stale `.new` mode).
    /// Optional + Identifiable lets `.sheet(item:)` present when non-nil and dismiss when nil.
    @State private var linkSheetRequest: LinkSheetRequest?
    @State private var linkedItems: [PlaidLinkedItem] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var itemPendingDelete: PlaidLinkedItem?

    @State private var isExportingDebug = false
    @State private var debugExportURL: URL?
    @State private var showDebugShare = false
    @State private var showDebugExportConfirm = false

    // @AppStorage ties a Bool to UserDefaults under a key — persists across launches.
    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false

    // body is required by View. @ViewBuilder lets you list views with if/forEach without
    // wrapping everything in explicit return / Group in many cases.
    var body: some View {
        // NavigationStack provides a navigation bar and push/pop of destination views.
        NavigationStack {
            // Form is a styled list for settings-style rows (sections, toggles, fields).
            Form {
                // MARK: Screenshot privacy
                // MARK: is an Xcode navigator bookmark — not runtime code.
                Section {
                    // Toggle binds to a Bool via $screenshotPrivacy ($ = two-way Binding).
                    Toggle(isOn: $screenshotPrivacy) {
                        Label("Hide for screenshots", systemImage: "eye.slash")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Masks dollar amounts and card last-four digits so you can share screenshots safely. Turn off when you’re done.")
                }

                // MARK: Credentials
                Section {
                    // $clientID is a Binding so the TextField can read and write the @State.
                    TextField("client_id", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    HStack {
                        // Group is an invisible container used to apply modifiers to either
                        // TextField or SecureField without duplicating the modifiers twice.
                        Group {
                            if showSecret {
                                TextField("secret", text: $secret)
                            } else {
                                // SecureField hides typed characters (password-style field).
                                SecureField("secret", text: $secret)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                        Button {
                            // toggle() flips a Bool: true ↔ false
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    // Picker writes the chosen case into $environment via .tag(env).
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
                } footer: {
                    // \(…) interpolates values into a string at runtime.
                    Text("Keys stay on this device. OAuth banks (Chase, etc.) use \(PlaidCredentialsStore.defaultRedirectURI) by default — add that exact URL under Plaid Dashboard → Allowed redirect URIs. Override only if you use a Universal Link. The app still finishes Link via financewizard://…")
                }

                // MARK: Linked banks
                Section {
                    if linkedItems.isEmpty {
                        Text("No banks linked yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        // ForEach builds one row per item. Items must be Identifiable (have id).
                        ForEach(linkedItems) { item in
                            HStack(spacing: 12) {
                                BankIconView(
                                    paymentMethod: item.institutionName,
                                    size: 36,
                                    displayName: item.institutionName,
                                    institutionName: item.institutionName
                                )
                                // VStack stacks views vertically; alignment: .leading left-aligns them.
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.institutionName)
                                        .font(.body.weight(.semibold))
                                    if item.needsRelink {
                                        Text(item.errorMessage ?? "Login expired — Relink required")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    } else if !item.accountNames.isEmpty {
                                        // joined(separator:) turns ["A","B"] into "A, B"
                                        Text(item.accountNames.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Linked \(item.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                // Spacer pushes content apart; minLength avoids zero-width collapse.
                                Spacer(minLength: 0)
                            }
                            // contentShape makes the whole row tappable for context menus, not just text.
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    startRelink(item)
                                } label: {
                                    Label("Relink…", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(!PlaidCredentialsStore.isConfigured)

                                // role: .destructive styles the action as destructive (often red).
                                Button(role: .destructive) {
                                    itemPendingDelete = item
                                } label: {
                                    Label("Unlink", systemImage: "trash")
                                }
                            }
                            // swipeActions adds buttons revealed by swiping a list/form row.
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    startRelink(item)
                                } label: {
                                    Label("Relink", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.blue)
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
                        // .new mode starts a brand-new bank Link flow (not update/relink).
                        linkSheetRequest = LinkSheetRequest(mode: .new)
                    } label: {
                        Label("Link bank account", systemImage: "plus.circle.fill")
                    }
                    .disabled(!PlaidCredentialsStore.isConfigured)
                } header: {
                    Text("Linked banks")
                } footer: {
                    Text("After linking, use Sync on Transactions. Swipe left for Relink if login expires, you want more accounts, or APR/due dates are missing (Relink adds the Liabilities product). Orange banners mean Plaid needs a Relink.")
                }

                // MARK: Sync info
                Section {
                    // LabeledContent is a title-on-left / value-on-right settings row.
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

                // if let unwraps an optional: only shows this section when statusMessage is non-nil.
                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .secondary)
                    }
                }

                // MARK: About
                Section {
                    // NavigationLink pushes a new screen onto the NavigationStack when tapped.
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
                                // ProgressView shows an indeterminate spinner while work runs.
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
            }
            .navigationTitle("Settings")
            // onAppear runs once when the view appears (good place to load stored values).
            .onAppear(perform: reload)
            // sheet(item:) presents when linkSheetRequest becomes non-nil; onDismiss runs after close.
            .sheet(item: $linkSheetRequest, onDismiss: reload) { request in
                PlaidLinkSheet(mode: request.mode) { result in
                    // switch matches Result success vs failure (Swift’s typed success/error enum).
                    switch result {
                    case .success(let item):
                        statusIsError = false
                        switch request.mode {
                        case .new:
                            statusMessage = "Linked \(item.institutionName). Tap Sync on Transactions."
                            // Task { } starts unstructured async work from a non-async context.
                            Task { await reconcileAfterRelink(item) }
                        case .update:
                            statusMessage = "Relinked \(item.institutionName). Refreshing accounts…"
                            Task { await reconcileAfterRelink(item) }
                        }
                    case .failure(let error):
                        statusIsError = true
                        // localizedDescription is a human-readable error string.
                        statusMessage = error.localizedDescription
                    }
                    reload()
                }
            }
            // onReceive listens to a NotificationCenter publisher (app-wide events).
            .onReceive(NotificationCenter.default.publisher(for: .plaidItemsReplaced)) { note in
                // userInfo is an optional dictionary attached to a notification.
                let ids = (note.userInfo?["itemIds"] as? [String]) ?? []
                guard !ids.isEmpty else { return }
                // try? turns a throwing call into nil on failure instead of propagating the error.
                let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
                // where filters the loop: only accounts whose itemId is in ids.
                for account in all where ids.contains(account.itemId) {
                    modelContext.delete(account)
                }
                try? modelContext.save()
                reload()
            }
            // confirmationDialog is a system action sheet (title + destructive/cancel buttons).
            .confirmationDialog(
                "Unlink \(itemPendingDelete?.institutionName ?? "bank")?",
                isPresented: Binding(
                    // Custom Binding: presented when itemPendingDelete is set; clearing dismisses.
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
            .sheet(isPresented: $showDebugShare, onDismiss: {
                debugExportURL = nil
            }) {
                if let debugExportURL {
                    ShareSheet(items: [debugExportURL]) {
                        showDebugShare = false
                    }
                }
            }
        }
    }

    // @MainActor means this async function must run on the main thread (required for UI state).
    @MainActor
    private func runDebugExport() async {
        isExportingDebug = true
        statusMessage = nil
        // defer runs when the function exits (success or error) — always clears the spinner flag.
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
        // Brief success flag, then hide the “Saved” label after 1.5 seconds.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSave = false
        }
    }

    /// Opens Plaid Link in update mode for an existing linked Item (relink / re-auth).
    private func startRelink(_ item: PlaidLinkedItem) {
        // guard else { return } exits early if the condition fails — keeps happy-path unindented.
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
    // UUID() creates a unique id each time a request is made (new sheet presentation).
    let id = UUID()
    let mode: PlaidLinkMode
}

// MARK: - Build info (from Info.plist / Xcode versions)

/// Reads marketing version, build number, and related values from the app’s Info.plist.
/// static members belong to the type itself (AppBuildInfo.x), not an instance.
enum AppBuildInfo {
    /// CFBundleShortVersionString ← MARKETING_VERSION (e.g. 1.0)
    static var marketingVersion: String {
        // as? is a conditional cast: succeeds as String or yields nil → then ?? provides default.
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
                        // textSelection allows long-press copy of the text.
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
                    // UIDevice is UIKit — systemVersion is the OS version string (e.g. "17.4").
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
        // .inline keeps the title in the nav bar center (not large title style).
        .navigationBarTitleDisplayMode(.inline)
    }
}

// #Preview is a SwiftUI canvas helper so Xcode can render this view without running the full app.
#Preview {
    SettingsView()
}
