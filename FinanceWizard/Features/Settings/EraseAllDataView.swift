//
//  EraseAllDataView.swift
//  Finance Wizard
//
//  Deletes everything on this device. Typing the word keeps it from being a single stray tap.
//

import SwiftData
import SwiftUI
import WidgetKit

struct EraseAllDataView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var confirmation = ""
    @State private var errorMessage: String?

    /// Exact match, so autocorrect or a stray word can't confirm it.
    static func isConfirmed(_ text: String) -> Bool {
        text == "DELETE"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This deletes all of Budget Magi's data on this device: transactions, income, accounts, budgets, payoff plans, your Ask chat, linked banks, and your Plaid, Anthropic, and xAI keys.")
                    Text("It can't be undone. Backup files you saved elsewhere aren't touched, and neither are your accounts with Plaid, Anthropic, or xAI. To stop Plaid's access to a bank, remove the bank in your Plaid account too.")
                }

                Section {
                    TextField("DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Type DELETE to confirm")
                }

                Section {
                    Button("Erase All Data", role: .destructive) { erase() }
                        .disabled(!Self.isConfirmed(confirmation))
                }
            }
            .navigationTitle("Erase All Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func erase() {
        guard Self.isConfirmed(confirmation) else { return }
        do {
            try PlaidConnectionBackup.eraseEverything(modelContext: modelContext)
            WidgetCenter.shared.reloadAllTimelines()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
