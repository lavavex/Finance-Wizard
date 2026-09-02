//
//  TransactionDetailView.swift
//  Finance Wizard
//
//  Tap a transaction → view details, edit category and payment rail (local only).
//

import SwiftUI
import SwiftData
import WidgetKit

/// Full detail form for a single transaction: view fields and edit category, rail, rewards.
struct TransactionDetailView: View {
    @Bindable var transaction: Transaction

    @Environment(\.modelContext) private var modelContext

    // Local drafts: Save copies onto the model. Separate so back-navigation doesn’t persist half-edits.
    @State private var categoryText: String = ""
    @State private var selectedRail: PaymentRail = .other
    @State private var subscriptionMode: SubscriptionDeclareMode = .auto
    @State private var learn = true
    @State private var scopePaymentMethod = true
    @State private var applyToMatching = false
    @State private var categoryOptions: [String] = KnownCategory.defaultNames
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSave = false
    @State private var saveStatusMessage: String?
    @State private var isSuggestingCategory = false
    /// FIX: .onAppear fires again when returning from the payoff editor or the category
    /// suggester, and it re-seeded the drafts from the model — silently discarding whatever
    /// the user had typed. Seed once per pushed view.
    @State private var didSeedDrafts = false
    /// FIX: this was `showPayoffEditor: Bool` + a separate `payoffEditorKind`, set in the same
    /// button action. `.sheet(isPresented:)` can build its content before the companion state
    /// lands, so the editor opened with the stale default — a My Chase Loan charge created a
    /// `payOverTime` plan with a flat monthly fee instead of a `myLoan` plan with an APR, and
    /// the whole payoff schedule was wrong. Carrying the kind *with* the presentation via
    /// `.sheet(item:)` makes that impossible to get wrong.
    @State private var payoffEditorRequest: PayoffEditorRequest?

    /// Identity wrapper so the editor's kind travels with the sheet presentation.
    private struct PayoffEditorRequest: Identifiable {
        let id = UUID()
        let kind: PayoffPlanKind
    }

    @Query private var allTransactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]
    @Query private var payoffPlans: [PayoffPlan]

    /// User control for subscription radar (yearly is the common missing case).
    private enum SubscriptionDeclareMode: String, CaseIterable, Identifiable {
        case auto
        case yearly
        case monthly
        case weekly
        case none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto-detect"
            case .yearly: return "Yearly"
            case .monthly: return "Monthly"
            case .weekly: return "Weekly"
            case .none: return "Not recurring"
            }
        }

        // What we store on the model (nil means “use auto detection”).
        var storageValue: String? {
            switch self {
            case .auto: return nil
            case .yearly: return SubscriptionCadence.yearly.rawValue
            case .monthly: return SubscriptionCadence.monthly.rawValue
            case .weekly: return SubscriptionCadence.weekly.rawValue
            case .none: return "none"
            }
        }

        static func from(transaction: Transaction) -> SubscriptionDeclareMode {
            if transaction.isDeclaredNotSubscription { return .none }
            switch transaction.declaredSubscriptionCadence {
            case .yearly: return .yearly
            case .monthly: return .monthly
            case .weekly: return .weekly
            case .none: return .auto
            }
        }
    }


    private var selectedPreset: String? {
        categoryOptions.first { $0 == categoryText }
    }

    private var linkedAccount: BankAccount? {
        BankAccount.matching(paymentMethod: transaction.paymentMethod, in: bankAccounts)
    }

    private var linkedPayoffPlan: PayoffPlan? {
        payoffPlans.first { $0.linkedTransactionId == transaction.transactionId }
    }

    private var suggestedPayoffKind: PayoffPlanKind? {
        if PayoffPlanRecognition.looksLikeLoanDisbursement(title: transaction.title) {
            return .myLoan
        }
        if PayoffPlanRecognition.looksLikeInstallmentBillingTitle(transaction.title)
            || transaction.category.caseInsensitiveCompare(TransactionAnalytics.installmentCategory) == .orderedSame {
            return .payOverTime
        }
        return nil
    }

    private var showsRecurringPicker: Bool {
        if suggestedPayoffKind != nil || linkedPayoffPlan != nil { return false }
        let category = categoryText.isEmpty ? transaction.category : categoryText
        return !TransactionAnalytics.isExcludedFromSpendCategory(category)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: CategoryStyle.symbolName(for: categoryText.isEmpty ? transaction.category : categoryText))
                        .font(.largeTitle)
                        .foregroundStyle(CategoryStyle.color(for: categoryText.isEmpty ? transaction.category : categoryText))
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.title)
                            .font(.title3.weight(.semibold))
                        MoneyText(transaction.amount)
                            .font(.title2.bold())
                            .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("Date") {
                    Text(transaction.date, style: .date)
                }
                LabeledContent("Account") {
                    HStack(spacing: 8) {
                        BankIconView(
                            paymentMethod: transaction.paymentMethod,
                            size: 24,
                            accountId: linkedAccount?.accountId,
                            displayName: CardLabelStore.label(
                                paymentMethod: transaction.paymentMethod,
                                accountId: linkedAccount?.accountId,
                                fallback: transaction.paymentMethod
                            ),
                            institutionId: linkedAccount?.institutionId,
                            institutionName: linkedAccount?.institutionName
                        )
                        CardText(
                            CardLabelStore.label(
                                paymentMethod: transaction.paymentMethod,
                                accountId: linkedAccount?.accountId,
                                fallback: transaction.paymentMethod
                            )
                        )
                        .multilineTextAlignment(.trailing)
                    }
                }
                // Optional fields only appear when Plaid provided them.
                if let channel = transaction.plaidPaymentChannel, !channel.isEmpty {
                    LabeledContent("Payment channel") {
                        Text(channel)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("ID") {
                    Text(transaction.transactionId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if transaction.isCategoryLocked || transaction.isPaymentRailLocked {
                    LabeledContent("Locked") {
                        Text(lockSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let source = transaction.overrideSource, !source.isEmpty {
                    LabeledContent("Override source") {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Category", selection: categoryPickerBinding) {
                    ForEach(categoryOptions, id: \.self) { name in
                        Label(name, systemImage: CategoryStyle.symbolName(for: name))
                            .tag(Optional(name))
                    }
                    Label("Custom…", systemImage: "pencil")
                        .tag(Optional<String>.none)
                }

                TextField("Category name", text: $categoryText)
                    .textInputAutocapitalization(.words)

                if OnDeviceAI.availabilityStatus() == .available {
                    Button {
                        Task { await suggestCategoryFromModel() }
                    } label: {
                        Label(
                            isSuggestingCategory ? "Suggesting…" : "Suggest with Apple Intelligence",
                            systemImage: "apple.intelligence"
                        )
                    }
                    .disabled(isSuggestingCategory)
                }
            } header: {
                Text("Spend category")
            } footer: {
                Text("Budget and Total Spend use this category.")
            }

            Section {
                Picker("Payment rail", selection: $selectedRail) {
                    ForEach(PaymentRail.allCases) { rail in
                        Label(rail.displayName, systemImage: rail.systemImage)
                            .tag(rail)
                    }
                }
            } header: {
                Text("Payment method")
            } footer: {
                Text("How the money left the account — card swipe versus bank transfer.")
            }

            if showsRecurringPicker {
                Section {
                    Picker("Repeats", selection: $subscriptionMode) {
                        ForEach(SubscriptionDeclareMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                } header: {
                    Text("Repeating bill")
                } footer: {
                    Text("For subscriptions and bills (phone, electric). Not for card loans or installments.")
                }
            }

            if linkedPayoffPlan != nil || suggestedPayoffKind != nil {
                Section {
                    if let plan = linkedPayoffPlan {
                        NavigationLink {
                            PayoffPlanEditorView(existing: plan)
                        } label: {
                            LabeledContent(plan.kind.displayName, value: plan.name)
                        }
                    } else if let kind = suggestedPayoffKind {
                        Button(kind == .myLoan ? "My Loan…" : "Pay over time…") {
                            payoffEditorRequest = PayoffEditorRequest(kind: kind)
                        }
                    }
                } header: {
                    Text("Installments")
                } footer: {
                    if suggestedPayoffKind == .myLoan || linkedPayoffPlan?.kind == .myLoan {
                        Text("This charge is the loan disbursement. The monthly amount is part of the card minimum and due with the statement.")
                    } else {
                        Text("Installment billing for this purchase. The monthly amount is part of the card minimum and due with the statement.")
                    }
                }
            }

            Section {
                Toggle("Remember for this vendor", isOn: $learn)
                Toggle("Only same card/account", isOn: $scopePaymentMethod)
                    .disabled(applyToMatching)
                Toggle("Apply to other matching transactions", isOn: $applyToMatching)
                    .onChange(of: applyToMatching) { _, isOn in
                        if isOn { scopePaymentMethod = true }
                    }
            } header: {
                Text("Remember")
            }

            if didSave {
                Section {
                    Label(saveStatusMessage ?? "Saved on this device", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $payoffEditorRequest) { request in
            NavigationStack {
                PayoffPlanEditorView(
                    defaultKind: request.kind,
                    defaultName: transaction.title,
                    defaultAccountId: linkedAccount?.accountId,
                    defaultPaymentMethod: transaction.paymentMethod,
                    defaultAmount: abs(transaction.amount),
                    defaultLinkedTransactionId: transaction.transactionId
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task { await saveEdits() }
                    }
                }
            }
        }
        .alert("Couldn’t save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear {
            guard !didSeedDrafts else { return }
            didSeedDrafts = true
            categoryText = transaction.category
            selectedRail = transaction.effectivePaymentRail
            subscriptionMode = .from(transaction: transaction)
            var merged = KnownCategory.defaultNames
            if !merged.contains(transaction.category), !transaction.category.isEmpty {
                merged.insert(transaction.category, at: 0)
            }
            categoryOptions = merged
        }
    }

    private var lockSummary: String {
        var parts: [String] = []
        if transaction.isCategoryLocked { parts.append("category") }
        if transaction.isPaymentRailLocked { parts.append("rail") }
        return parts.joined(separator: " + ")
    }

    /// Picker selection is String? so “Custom…” can be nil without clearing the text field.
    private var categoryPickerBinding: Binding<String?> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                // Only write when a preset name is chosen; nil (Custom) leaves free text alone.
                if let newValue {
                    categoryText = newValue
                }
            }
        )
    }


    @MainActor
    private func suggestCategoryFromModel() async {
        isSuggestingCategory = true
        defer { isSuggestingCategory = false }
        do {
            let name = try await OnDeviceAI.suggestCategory(
                title: transaction.title,
                amount: transaction.amount,
                allowedCategories: categoryOptions
            )
            categoryText = name
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func saveEdits() async {
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategory.isEmpty else {
            saveError = "Category can’t be empty."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let cardScoped = scopePaymentMethod || applyToMatching

            // FIX: Save used to rewrite and lock every field unconditionally and stamp
            // overrideSource = "user". Opening a row and pressing Save with no edits therefore
            // froze it against all future Sync corrections, and it erased provenance markers —
            // a My Chase Loan charge adopted by the payoff editor ("my-loan") became "user",
            // which is how a $4,000 loan picked up a bill-payment row. Only touch what changed.
            let categoryChanged =
                trimmedCategory.caseInsensitiveCompare(transaction.category) != .orderedSame
            let railChanged = selectedRail != transaction.effectivePaymentRail
            let cadenceChanged = subscriptionMode.storageValue != transaction.subscriptionCadenceOverride

            if categoryChanged {
                transaction.category = trimmedCategory
                transaction.categoryLocked = true
            }
            if railChanged {
                transaction.paymentRail = selectedRail.rawValue
                transaction.paymentRailLocked = true
            }
            if cadenceChanged {
                transaction.subscriptionCadenceOverride = subscriptionMode.storageValue
            }
            // Provenance survives a no-op save; a real edit is the user's.
            if categoryChanged || railChanged || cadenceChanged {
                transaction.overrideSource = "user"
            }
            // FIX: this was outside the change guards, so opening a row and pressing Save
            // re-stamped the cadence across the vendor. It also keys on vendor name alone
            // while the detector keys declared subs on "vendor|cadence", so one merchant
            // could not hold a monthly and a yearly charge.
            if cadenceChanged {
                propagateRecurringCadence()
            }

            // Keep CreditCardPayment table + spend exclusion in sync with the category choice.
            // Only when it actually moved — this is what mirrors (or drops) the payment row.
            if categoryChanged {
                syncCreditPaymentRecord(for: transaction, category: trimmedCategory)
            }

            // Learn rule for future Plaid syncs (skip bill-payment category)
            // FIX: `learn` defaults to true and this was outside the category guard, so
            // merely opening a Miscellaneous row and tapping Save wrote a permanent
            // vendor+card → Miscellaneous rule that then beat Plaid's PFC on every future
            // row, with no UI to remove it.
            if learn, categoryChanged, !TransactionAnalytics.isExcludedFromSpendCategory(trimmedCategory) {
                VendorRulesStore.upsert(
                    vendor: transaction.title,
                    paymentMethod: cardScoped ? transaction.paymentMethod : nil,
                    category: trimmedCategory
                )
            }

            var localExtra = 0
            if applyToMatching, categoryChanged || cadenceChanged {
                localExtra = applyLocalMatching(
                    category: trimmedCategory,
                    applyCategory: categoryChanged,
                    applyCadence: cadenceChanged
                )
            }

            try modelContext.save()
            WidgetCenter.shared.reloadAllTimelines()

            if subscriptionMode == .yearly {
                saveStatusMessage = "Saved as yearly recurring."
            } else if subscriptionMode == .monthly {
                saveStatusMessage = "Saved as monthly recurring."
            } else if subscriptionMode == .weekly {
                saveStatusMessage = "Saved as weekly recurring."
            } else if TransactionAnalytics.isCreditCardPaymentCategory(trimmedCategory) {
                saveStatusMessage = "Saved as Credit Card Payment (excluded from Total Spend)."
            } else if TransactionAnalytics.isExcludedFromSpendCategory(trimmedCategory) {
                // Loan / Refund / Installment are excluded too, but they are not payments.
                saveStatusMessage = "Saved as \(trimmedCategory) (excluded from Total Spend)."
            } else if localExtra > 0 {
                saveStatusMessage = "Saved. Updated \(localExtra + 1) transactions on this card."
            } else {
                saveStatusMessage = "Saved on this device"
            }
            didSave = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                didSave = false
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Mirror category onto CreditCardPayment (Accounts “Total paid”) or remove if reclassified.
    private func syncCreditPaymentRecord(for row: Transaction, category: String) {
        let targetId = row.transactionId
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { p in
                p.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1
        let existing = try? modelContext.fetch(descriptor).first

        // FIX: this used isExcludedFromSpendCategory, which is true for Loan, Refund and
        // Installment as well as Credit Card Payment — those are excluded from spend for
        // different reasons and are not bill payments. Re-filing the $4,000 My Chase Loan
        // charge as Loan therefore created a $4,000 payment row, re-inflating Total paid by
        // exactly the amount the sync-side fix had just removed. Only a card payment mirrors.
        // OLD: if TransactionAnalytics.isExcludedFromSpendCategory(category) {
        if TransactionAnalytics.isCreditCardPaymentCategory(category) {
            if let existing {
                existing.amount = abs(row.amount)
                existing.date = row.date
                existing.cardName = row.paymentMethod
                existing.title = row.title
            } else {
                // FIX: cardName was the *funding* account, but cardName is what
                // AccountsBoard.paymentsMatching and paymentIdentities treat as the card's
                // identity — so re-filing "ONLINE PAYMENT TO CHASE CARD ENDING 1234" produced
                // a payment attributed to checking, missing from that card's Total paid and
                // deduplicated against the wrong mask. Resolve the card from the title.
                let maskMatch = CreditAnalytics.extractMask(from: row.title).flatMap { mask in
                    bankAccounts.first { $0.isCredit && $0.mask == mask }
                }
                let onCredit = linkedAccount?.isCredit == true
                let card = maskMatch ?? (onCredit ? linkedAccount : nil)
                modelContext.insert(
                    CreditCardPayment(
                        transactionId: row.transactionId,
                        amount: abs(row.amount),
                        date: row.date,
                        cardName: card?.plaidDisplayName ?? row.paymentMethod,
                        sourceAccount: onCredit ? nil : row.paymentMethod,
                        title: row.title,
                        creditAccountId: card?.accountId,
                        institutionName: card?.institutionName ?? linkedAccount?.institutionName
                    )
                )
            }
        } else if let existing {
            // Reclassified away from bill-pay → drop the mirrored payment row.
            modelContext.delete(existing)
        }
    }

    /// Apply the changed fields to other transactions with the same title + card.
    /// FIX: this used to write category, lock and cadence on every sibling regardless of what
    /// actually changed — and `subscriptionMode.storageValue` is nil for `.auto`, so it erased
    /// the "not recurring" markers written from the Recurring tab and the vendor reappeared.
    @discardableResult
    private func applyLocalMatching(
        category: String,
        applyCategory: Bool,
        applyCadence: Bool
    ) -> Int {
        let vendor = transaction.title
        let card = transaction.paymentMethod
        var count = 0

        for row in allTransactions {
            if row.transactionId == transaction.transactionId { continue }
            guard row.title.caseInsensitiveCompare(vendor) == .orderedSame else { continue }
            guard row.paymentMethod.caseInsensitiveCompare(card) == .orderedSame else { continue }

            if applyCategory {
                row.category = category
                row.categoryLocked = true
            }
            if applyCadence {
                row.subscriptionCadenceOverride = subscriptionMode.storageValue
            }
            row.overrideSource = "user"
            count += 1
        }
        return count
    }

    /// Monthly/yearly/weekly on one charge covers the same vendor even when amounts differ.
    private func propagateRecurringCadence() {
        guard subscriptionMode == .yearly || subscriptionMode == .monthly || subscriptionMode == .weekly,
              let value = subscriptionMode.storageValue else {
            return
        }
        let vendor = SubscriptionAnalytics.normalizeVendor(transaction.title)
        guard vendor.count >= 2 else { return }
        for row in allTransactions {
            if row.transactionId == transaction.transactionId { continue }
            guard SubscriptionAnalytics.normalizeVendor(row.title) == vendor else { continue }
            if row.isDeclaredNotSubscription { continue }
            if (row.subscriptionCadenceOverride ?? "").lowercased() == "cancelled" { continue }
            row.subscriptionCadenceOverride = value
        }
    }
}

#Preview {
    NavigationStack {
        Text("Open a transaction from the list")
    }
}
