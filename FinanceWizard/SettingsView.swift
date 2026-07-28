//
//  SettingsView.swift
//  Finance Wizard
//
//  Plaid developer credentials, linked banks, and sync info.
//

import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var clientID: String = ""
    @State private var secret: String = ""
    @State private var environment: PlaidEnvironment = .sandbox
    @State private var didSave = false
    @State private var showSecret = false
    @State private var showLinkSheet = false
    @State private var linkedItems: [PlaidLinkedItem] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var itemPendingDelete: PlaidLinkedItem?

    @State private var isExportingDebug = false
    @State private var debugExportURL: URL?
    @State private var showDebugShare = false
    @State private var showDebugExportConfirm = false

    var body: some View {
        NavigationStack {
            Form {
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

                    Button("Save credentials") {
                        saveCredentials()
                    }

                    if didSave {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Plaid developer account")
                } footer: {
                    Text("Keys: dashboard.plaid.com → Developers → Keys. Link uses Plaid Hosted Link (secure browser) and returns via \(PlaidHostedLink.completionRedirectURI). Secrets stay on this device (Keychain).")
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
                                    if !item.accountNames.isEmpty {
                                        Text(item.accountNames.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Linked \(item.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
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
                        showLinkSheet = true
                    } label: {
                        Label("Link bank account", systemImage: "plus.circle.fill")
                    }
                    .disabled(!PlaidCredentialsStore.isConfigured)
                } header: {
                    Text("Linked banks")
                } footer: {
                    Text("Link uses Plaid Hosted Link with your own API keys (transactions + credit details when supported). After linking, Sync on Transactions. Re-link older banks once if credit APR/due dates are missing.")
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
                    LabeledContent("API host") {
                        Text(PlaidCredentialsStore.environment.baseURL.host() ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Sync on the Transactions tab calls Plaid /transactions/sync for each linked bank and stores results in SwiftData (App Group) for the widgets.")
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
                } footer: {
                    Text("Version \(AppBuildInfo.versionBuildLabel). Debug export is a local zip (no Plaid secrets).")
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: reload)
            .sheet(isPresented: $showLinkSheet, onDismiss: reload) {
                PlaidLinkSheet { result in
                    switch result {
                    case .success(let item):
                        statusIsError = false
                        statusMessage = "Linked \(item.institutionName). Tap Sync on Transactions."
                    case .failure(let error):
                        statusIsError = true
                        statusMessage = error.localizedDescription
                    }
                    reload()
                }
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
                Text("Removes the access token from this device. Optionally also remove the Item from Plaid.")
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
                Text("Includes transaction titles, amounts, and account masks. Excludes Plaid secrets and access tokens.")
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

    private func reload() {
        clientID = PlaidCredentialsStore.clientID
        secret = PlaidCredentialsStore.secret
        environment = PlaidCredentialsStore.environment
        // Drop legacy localhost OAuth redirect (Hosted Link does not need it)
        PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
        linkedItems = PlaidItemStore.loadItems()
    }

    private func saveCredentials() {
        PlaidCredentialsStore.clientID = clientID
        PlaidCredentialsStore.secret = secret
        PlaidCredentialsStore.environment = environment
        PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
        didSave = true
        statusIsError = false
        statusMessage = "Credentials saved on this device."
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSave = false
        }
    }

    private func unlink(_ item: PlaidLinkedItem) {
        Task {
            // Best-effort remote remove
            try? await PlaidAPIClient.removeItem(accessToken: item.accessToken)
            await MainActor.run {
                PlaidItemStore.remove(itemID: item.id)
                reload()
                statusIsError = false
                statusMessage = "Unlinked \(item.institutionName)."
            }
        }
    }
}

// MARK: - Build info (from Info.plist / Xcode versions)

enum AppBuildInfo {
    /// CFBundleShortVersionString ← MARKETING_VERSION (e.g. 0.1)
    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// CFBundleVersion ← CURRENT_PROJECT_VERSION (e.g. 5)
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

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
            } footer: {
                Text("These come from the installed app’s Info.plist. Xcode Cloud sets them from the target’s Version (MARKETING_VERSION) and Build (CURRENT_PROJECT_VERSION) when it archives.")
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
