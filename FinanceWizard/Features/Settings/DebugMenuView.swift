//
//  DebugMenuView.swift
//  Finance Wizard
//
//  Developer tools in Settings: inspect and reset local state without deleting the app.
//  Does not change anything in the Plaid Dashboard.
//

import SwiftUI
import SwiftData
import WidgetKit

/// Confirmation target so one dialog can serve several destructive actions.
private enum DebugPendingAction: String, Identifiable {
    case resetCursors
    case clearVendorRules
    case clearNicknames
    case clearCadenceOverrides
    case clearLogos
    case resetBudget
    case clearBenefits
    case wipeEverything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resetCursors: return "Reset sync cursors?"
        case .clearVendorRules: return "Clear learned vendor rules?"
        case .clearNicknames: return "Clear card nicknames?"
        case .clearCadenceOverrides: return "Clear Recurring marks?"
        case .clearLogos: return "Clear cached logos?"
        case .resetBudget: return "Reset budget plan?"
        case .clearBenefits: return "Reset card rewards profiles?"
        case .wipeEverything: return "Wipe all local data?"
        }
    }

    var message: String {
        switch self {
        case .resetCursors:
            return "The next Sync will re-download full history for every linked bank. Transactions already on this device stay until Sync merges them."
        case .clearVendorRules:
            return "Removes category/multiplier rules learned from your edits. Future Sync will not auto-apply them."
        case .clearNicknames:
            return "Account and payment-method nicknames go back to bank names."
        case .clearCadenceOverrides:
            return "Removes Not Recurring / Cancelled marks on charges. Recurring will detect those vendors again."
        case .clearLogos:
            return "Deletes cached institution logos. They will fetch again as tiles appear."
        case .resetBudget:
            return "Deletes the saved monthly cap, category limits, and expected income. A blank plan is created."
        case .clearBenefits:
            return "Removes saved rewards profiles. Defaults rebuild the next time a card is opened."
        case .wipeEverything:
            return "Deletes transactions, income, accounts, budget, linked banks, prefs, and logos on this device. Plaid Dashboard is unchanged. You will need to link banks again."
        }
    }

    var confirmTitle: String {
        switch self {
        case .wipeEverything: return "Wipe everything"
        default: return "Reset"
        }
    }
}

/// Settings → Debug. Toggle onboarding, inspect counts, reset local stores.
struct DebugMenuView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Query private var accounts: [BankAccount]
    @Query private var payments: [CreditCardPayment]
    @Query private var budgetPlans: [BudgetPlan]
    @Query private var recurringStreams: [RecurringStream]

    @AppStorage(OnboardingStore.storageKey) private var onboardingCompleted = false
    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false

    @State private var pending: DebugPendingAction?
    @State private var statusMessage: String?

    private var linkedBanks: [PlaidLinkedItem] {
        PlaidItemStore.loadItems()
    }

    private var vendorRuleCount: Int {
        VendorRulesStore.load().count
    }

    private var cadenceOverrideCount: Int {
        transactions.filter { ($0.subscriptionCadenceOverride ?? "").isEmpty == false }.count
    }

    private var preferenceKeys: [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { key in
                ["plaid.", "card.", "settings."].contains { key.hasPrefix($0) }
            }
            .sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Onboarding completed", isOn: $onboardingCompleted)
                Button("Replay onboarding") {
                    onboardingCompleted = false
                }
            } header: {
                Text("Onboarding")
            } footer: {
                Text("Off (or Replay) shows Welcome immediately. Get Started writes the flag again.")
            }

            Section {
                Toggle("Hide for screenshots", isOn: $screenshotPrivacy)
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Transactions", value: "\(transactions.count)")
                LabeledContent("Income", value: "\(incomeRows.count)")
                LabeledContent("Accounts", value: "\(accounts.count)")
                LabeledContent("Card payments", value: "\(payments.count)")
                LabeledContent("Budget plans", value: "\(budgetPlans.count)")
                LabeledContent("Recurring streams", value: "\(recurringStreams.count)")
                LabeledContent("Recurring marks", value: "\(cadenceOverrideCount)")
                LabeledContent("Linked banks", value: "\(linkedBanks.count)")
                LabeledContent("Vendor rules", value: "\(vendorRuleCount)")
            } header: {
                Text("Local counts")
            }

            Section {
                LabeledContent("Plaid configured", value: PlaidCredentialsStore.isConfigured ? "Yes" : "No")
                LabeledContent("Environment", value: PlaidCredentialsStore.environment.displayName)
                LabeledContent("Client ID", value: PlaidCredentialsStore.clientID.isEmpty ? "—" : PlaidCredentialsStore.clientID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Plaid")
            } footer: {
                Text("Credentials stay in Settings → Plaid account. This panel does not show the secret.")
            }

            Section {
                Button("Reset sync cursors") { pending = .resetCursors }
                Button("Clear learned vendor rules") { pending = .clearVendorRules }
                Button("Clear card nicknames") { pending = .clearNicknames }
                Button("Clear Recurring marks") { pending = .clearCadenceOverrides }
                Button("Clear cached logos") { pending = .clearLogos }
                Button("Reset budget plan") { pending = .resetBudget }
                Button("Reset card rewards profiles") { pending = .clearBenefits }
            } header: {
                Text("Reset pieces")
            } footer: {
                Text("Each action is local. Linked banks stay linked unless you Wipe everything.")
            }

            Section {
                Button("Wipe all local data", role: .destructive) {
                    pending = .wipeEverything
                }
            } header: {
                Text("Nuclear")
            } footer: {
                Text("Same as a wipe-then-restore with no backup: SwiftData, Plaid items, prefs, logos.")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(preferenceKeys, id: \.self) { key in
                    LabeledContent(key) {
                        Text(preferenceSummary(for: key))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Prefs (\(preferenceKeys.count))")
            } footer: {
                Text("Keys under plaid., card., and settings. Secrets in Keychain are not listed.")
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(pending.confirmTitle, role: pending == .wipeEverything ? .destructive : nil) {
                    perform(pending)
                    self.pending = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pending = nil
            }
        } message: {
            Text(pending?.message ?? "")
        }
    }

    private func preferenceSummary(for key: String) -> String {
        let value = UserDefaults.standard.object(forKey: key)
        switch value {
        case let flag as Bool:
            return flag ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let text as String:
            return text.count > 24 ? String(text.prefix(24)) + "…" : text
        case let data as Data:
            return "\(data.count) bytes"
        case is [Any]:
            return "array"
        case is [AnyHashable: Any]:
            return "dictionary"
        default:
            return String(describing: type(of: value))
        }
    }

    private func perform(_ action: DebugPendingAction) {
        switch action {
        case .resetCursors:
            PlaidItemStore.resetAllCursors()
            statusMessage = "Cursors cleared. Tap Sync on Transactions."
        case .clearVendorRules:
            VendorRulesStore.save([])
            statusMessage = "Vendor rules cleared."
        case .clearNicknames:
            CardLabelStore.removeAll()
            statusMessage = "Nicknames cleared."
        case .clearCadenceOverrides:
            var count = 0
            for tx in transactions where !(tx.subscriptionCadenceOverride ?? "").isEmpty {
                tx.subscriptionCadenceOverride = nil
                count += 1
            }
            try? modelContext.save()
            statusMessage = "Cleared \(count) Recurring mark(s)."
        case .clearLogos:
            InstitutionLogoCache.wipeAllLogoFiles()
            statusMessage = "Logo cache cleared."
        case .resetBudget:
            for plan in budgetPlans {
                modelContext.delete(plan)
            }
            try? modelContext.save()
            _ = BudgetStore.loadOrCreate(in: modelContext)
            statusMessage = "Budget plan reset."
        case .clearBenefits:
            CardBenefitsStore.clearAllProfiles()
            statusMessage = "Rewards profiles reset."
        case .wipeEverything:
            do {
                try PlaidConnectionBackup.wipeLocalAppData(modelContext: modelContext)
                onboardingCompleted = false
                WidgetCenter.shared.reloadAllTimelines()
                statusMessage = "Local data wiped. Replay onboarding is on."
            } catch {
                statusMessage = "Wipe failed: \(error.localizedDescription)"
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#Preview {
    NavigationStack {
        DebugMenuView()
    }
}
