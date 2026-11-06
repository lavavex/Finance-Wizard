//
//  AskProviderSetupView.swift
//  Finance Wizard
//
//  API key and consent for a cloud model. Nothing is sent to a provider until the user agrees here.
//

import SwiftUI

struct AskProviderSetupView: View {
    let provider: AskProvider
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("When you ask \(provider.name), Budget Magi sends \(provider.company) your question, recent questions and answers in this chat, and the data needed to answer: merchant names, amounts, dates, categories, banks, account names with their last four digits, balances, and budget figures.")
                Text("Bank logins and Plaid keys are never sent. \(provider.company) handles this data under its own terms, and usage is billed to your API account. On-device answers never leave this device.")
                Link("\(provider.company) privacy policy", destination: provider.privacyURL)
            } header: {
                Text("What gets sent")
            }

            Section {
                SecureField(hasKey ? "Saved. Enter a new key to replace it" : "API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Link("Get a key from \(provider.company)", destination: provider.keysURL)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Your API key")
            } footer: {
                Text("Stored in the Keychain on this device. It isn't included in backups.")
            }

            Section {
                Button("Agree and Save") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("Remove Key", role: .destructive) {
                        provider.removeKeyAndConsent()
                        if AskModel.selected.provider == provider { AskModel.selected = .onDevice }
                        hasKey = false
                        key = ""
                    }
                }
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hasKey = provider.apiKey != nil }
    }

    private func save() {
        do {
            try provider.saveKeyAndConsent(key)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Couldn't save the key to the Keychain."
        }
    }
}
