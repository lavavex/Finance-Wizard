//
//  SettingsView.swift
//  Finance Wizard
//
//  Plaid developer credentials, linked banks, and sync info.
//

import SwiftUI

struct SettingsView: View {
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
                    Text("Create free keys at dashboard.plaid.com → Developers → Keys. Use the Sandbox secret while testing with fake banks. Secrets stay on this device (Keychain). Never share them or commit them to git.")
                }

                // MARK: Linked banks
                Section {
                    if linkedItems.isEmpty {
                        Text("No banks linked yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedItems) { item in
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
                    Text("Link uses Plaid Link with your own API keys. After linking, tap Sync on Transactions to pull transactions.")
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
        }
    }

    private func reload() {
        clientID = PlaidCredentialsStore.clientID
        secret = PlaidCredentialsStore.secret
        environment = PlaidCredentialsStore.environment
        linkedItems = PlaidItemStore.loadItems()
    }

    private func saveCredentials() {
        PlaidCredentialsStore.clientID = clientID
        PlaidCredentialsStore.secret = secret
        PlaidCredentialsStore.environment = environment
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

#Preview {
    SettingsView()
}
