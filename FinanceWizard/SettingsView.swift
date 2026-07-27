//
//  SettingsView.swift
//  Finance Wizard
//
//  App settings: sync server URL and info about which months Sync pulls.
//

import SwiftUI

struct SettingsView: View {
    // Persisted server base URL (same key as AppSettings.serverBaseURLKey)
    @AppStorage(AppSettings.serverBaseURLKey)
    private var serverBaseURL: String = AppSettings.defaultServerBaseURL

    // Local draft so typing doesn’t fight UserDefaults mid-edit as much
    @State private var serverDraft: String = ""
    // Show a quick “Saved” confirmation
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            Form {
                // Server connection
                Section {
                    TextField("http://host:8787", text: $serverDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    Button("Save server URL") {
                        saveServerURL()
                    }

                    Button("Reset to default") {
                        serverDraft = AppSettings.defaultServerBaseURL
                        saveServerURL()
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Sync server")
                } footer: {
                    Text("Base URL of finance-sync (no path). Example: \(AppSettings.defaultServerBaseURL). Use http only on a trusted LAN; ATS must allow local networking.")
                }

                // What Sync will request
                Section {
                    LabeledContent("Recent months") {
                        Text(AppSettings.syncMonthsDescription())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Sync everything") {
                        Text("All expenses + income")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Active URL") {
                        Text(AppSettings.serverBaseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Sync behavior")
                } footer: {
                    Text("On the Transactions tab, open Sync → “Sync recent months” (current + previous) or “Sync everything” (unfiltered GET /api/transactions and GET /api/income). Income is never included in Total Spend.")
                }

                if didSave {
                    Section {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                // Load current value into the text field
                serverDraft = serverBaseURL.isEmpty
                    ? AppSettings.defaultServerBaseURL
                    : serverBaseURL
            }
        }
    }

    private func saveServerURL() {
        var trimmed = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        if trimmed.isEmpty {
            trimmed = AppSettings.defaultServerBaseURL
        }
        serverBaseURL = trimmed
        serverDraft = trimmed
        didSave = true
        // Hide the checkmark after a moment
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSave = false
        }
    }
}

#Preview {
    SettingsView()
}
