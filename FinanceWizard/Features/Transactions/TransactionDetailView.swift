//
//  TransactionDetailView.swift
//  Finance Wizard
//
//  Tap a transaction → view details, edit category / multiplier (local only).
//  Teaches: @Bindable, Form, @State, custom Binding, onChange, .task, async/await, @MainActor.
//

import SwiftUI
import SwiftData
import WidgetKit

// Detail + edit screen for one SwiftData transaction
/// Full detail form for a single transaction: view fields and edit category, rail, rewards.
struct TransactionDetailView: View {
    // @Bindable (Observation) lets Form controls write into a SwiftData model’s properties
    // when you use $transaction.someField. Here we mostly edit via local @State then Save.
    @Bindable var transaction: Transaction

    // SwiftData context for fetch / insert / delete / save.
    @Environment(\.modelContext) private var modelContext

    // Local drafts: user edits these, then Save copies them onto the model.
    // Keeping drafts separate avoids half-edited values on the model if the user navigates back.
    @State private var categoryText: String = ""
    @State private var multiplierText: String = ""
    @State private var selectedRail: PaymentRail = .other
    /// nil = auto from general category + title; else locked reward bucket name
    @State private var rewardOverrideMode: RewardTravelMode = .auto
    @State private var subscriptionMode: SubscriptionDeclareMode = .auto
    @State private var learn = true
    @State private var scopePaymentMethod = true
    @State private var applyToMatching = false
    @State private var categoryOptions: [String] = KnownCategory.defaultNames
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSave = false
    @State private var saveStatusMessage: String?

    // Extra queries for bulk apply + account reward rates.
    @Query private var allTransactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]

    /// User control for subscription radar (yearly is the common missing case).
    /// Nested private enum: only used inside this view (keeps the file self-contained).
    /// String raw values + CaseIterable + Identifiable make it Picker-friendly.
    private enum SubscriptionDeclareMode: String, CaseIterable, Identifiable {
        case auto
        case yearly
        case monthly
        case weekly
        case none

        // Identifiable requires a stable id — rawValue works for simple string enums.
        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto-detect"
            case .yearly: return "Yearly subscription"
            case .monthly: return "Monthly subscription"
            case .weekly: return "Weekly subscription"
            case .none: return "Not a subscription"
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

        // Factory: map a Transaction’s stored override back into the picker mode.
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

    /// Travel-specific reward bucket (portal vs direct) when the general category is Travel.
    private enum RewardTravelMode: String, CaseIterable, Identifiable {
        case auto
        case portal
        case otherTravel
        case clear

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .portal: return "Portal"
            case .otherTravel: return "Direct / other"
            case .clear: return "Auto"
            }
        }
    }

    // Which preset in the Picker matches the free-text category field (if any).
    private var selectedPreset: String? {
        categoryOptions.first { $0 == categoryText }
    }

    // Bank account linked to this payment method (for logos and reward rates).
    private var linkedAccount: BankAccount? {
        BankAccount.matching(paymentMethod: transaction.paymentMethod, in: bankAccounts)
    }

    private var benefitsProfile: CardBenefitsProfile {
        CardBenefitsStore.profile(
            accountId: linkedAccount?.accountId,
            paymentMethod: transaction.paymentMethod,
            accounts: bankAccounts
        )
    }

    // Maps general spend category (+ optional override) into a reward earn bucket.
    private var mappedRewardCategory: RewardCategory {
        if rewardOverrideMode == .portal { return .travelPortal }
        if rewardOverrideMode == .otherTravel { return .travelOther }
        if let raw = transaction.rewardCategoryOverride,
           let match = RewardCategory.allCases.first(where: {
               // caseInsensitiveCompare == .orderedSame means equal ignoring case.
               $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame
           }) {
            return match
        }
        return RewardCategory.forTransaction(
            generalCategory: categoryText.isEmpty ? transaction.category : categoryText,
            title: transaction.title
        )
    }

    private var suggestedRewardRate: Double {
        benefitsProfile.rate(
            forCategory: mappedRewardCategory.rawValue,
            on: transaction.date
        )
    }

    // Show the travel earn picker only when travel-related.
    private var showsTravelRewardPicker: Bool {
        let general = (categoryText.isEmpty ? transaction.category : categoryText).lowercased()
        let reward = mappedRewardCategory
        return general.contains("travel")
            || reward == .travelPortal
            || reward == .travelOther
            || transaction.rewardCategoryOverride != nil
    }

    var body: some View {
        // Form is like List but optimized for settings-style inputs (pickers, toggles, fields).
        Form {
            // Hero: icon + title + amount
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
                        // textSelection lets the user long-press to copy.
                        .textSelection(.enabled)
                }
                if transaction.isCategoryLocked || transaction.isMultiplierLocked || transaction.isPaymentRailLocked {
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
                // categoryPickerBinding is a custom Binding so “Custom…” can mean “no preset.”
                Picker("Category", selection: categoryPickerBinding) {
                    ForEach(categoryOptions, id: \.self) { name in
                        Label(name, systemImage: CategoryStyle.symbolName(for: name))
                            .tag(Optional(name))
                    }
                    Label("Custom…", systemImage: "pencil")
                        .tag(Optional<String>.none)
                }

                // Free-text category (always editable; Picker fills this when a preset is chosen).
                TextField("Category name", text: $categoryText)
                    .textInputAutocapitalization(.words)

                // Dual system: general spend category vs Benefits earn bucket
                LabeledContent("Reward category") {
                    HStack(spacing: 6) {
                        Image(systemName: CategoryStyle.symbolName(forReward: mappedRewardCategory.rawValue))
                            .foregroundStyle(CategoryStyle.color(forReward: mappedRewardCategory.rawValue))
                        Text(mappedRewardCategory.rawValue)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Card rate") {
                    Text(benefitsProfile.formatRate(suggestedRewardRate))
                        .foregroundStyle(.secondary)
                }

                if showsTravelRewardPicker {
                    Picker("Travel earn", selection: $rewardOverrideMode) {
                        Text("Auto").tag(RewardTravelMode.auto)
                        Text("Portal").tag(RewardTravelMode.portal)
                        Text("Direct / other").tag(RewardTravelMode.otherTravel)
                    }
                    // onChange runs when the value changes; two-parameter form is (old, new).
                    .onChange(of: rewardOverrideMode) { _, mode in
                        applyTravelModeToMultiplier(mode)
                    }
                }

                Picker("Payment rail", selection: $selectedRail) {
                    ForEach(PaymentRail.allCases) { rail in
                        Label(rail.displayName, systemImage: rail.systemImage)
                            .tag(rail)
                    }
                }
                .onChange(of: selectedRail) { _, newRail in
                    // Suggest account reward multiplier for this rail when not yet custom-locked
                    if !transaction.isMultiplierLocked,
                       let suggested = linkedAccount?.rewardMultiplier(for: newRail) {
                        multiplierText = formatMultiplier(suggested)
                    }
                }

                HStack {
                    Text("Points / rewards mult.")
                    Spacer()
                    TextField("1", text: $multiplierText)
                        // decimalPad shows a number keyboard (no Return key).
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                    Text(benefitsProfile.rewardKind.rateSuffix)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Edit")
            }

            Section {
                Picker("Subscription", selection: $subscriptionMode) {
                    ForEach(SubscriptionDeclareMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Recurring")
            } footer: {
                Text("Mark bills so they appear under Recurring.")
            }

            Section {
                // Toggle is an on/off switch bound to Bool @State.
                Toggle("Remember for this vendor", isOn: $learn)
                Toggle("Only same card/account", isOn: $scopePaymentMethod)
                    // .disabled grays out the control when applyToMatching forces scope on.
                    .disabled(applyToMatching)
                Toggle("Apply to other matching transactions", isOn: $applyToMatching)
                    .onChange(of: applyToMatching) { _, isOn in
                        if isOn { scopePaymentMethod = true }
                    }
            } header: {
                Text("Remember")
            }

            Section("Points (estimate)") {
                // Local let inside a ViewBuilder is allowed (Swift 5.5+).
                let points = abs(transaction.amount) * (Double(multiplierText.replacingOccurrences(of: ",", with: ".")) ?? transaction.multiplier)
                LabeledContent("Points") {
                    // FormatStyle for numbers with flexible fraction digits.
                    Text(points, format: .number.precision(.fractionLength(0...2)))
                }
                LabeledContent("~ Value @ 1¢/pt") {
                    MoneyText(points * 0.01)
                }
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
        .toolbar {
            // confirmationAction is the standard top-right “done/save” placement.
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        // Task bridges async saveEdits into a button action (which is sync).
                        Task { await saveEdits() }
                    }
                }
            }
        }
        // .alert presents a modal dialog. isPresented uses a Binding derived from saveError.
        .alert("Couldn’t save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            // role: .cancel is the dismiss-style button.
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        // onAppear runs once when the view enters the hierarchy — seed drafts from the model.
        .onAppear {
            categoryText = transaction.category
            multiplierText = formatMultiplier(transaction.multiplier)
            selectedRail = transaction.effectivePaymentRail
            subscriptionMode = .from(transaction: transaction)
            if let raw = transaction.rewardCategoryOverride {
                if raw.caseInsensitiveCompare(RewardCategory.travelPortal.rawValue) == .orderedSame {
                    rewardOverrideMode = .portal
                } else if raw.caseInsensitiveCompare(RewardCategory.travelOther.rawValue) == .orderedSame {
                    rewardOverrideMode = .otherTravel
                } else {
                    rewardOverrideMode = .auto
                }
            } else {
                rewardOverrideMode = .auto
            }
        }
        // .task starts async work when the view appears (cancels if the view goes away).
        .task {
            let names = await FinanceSyncAPI.fetchCategories()
            if !names.isEmpty {
                var merged = names
                if !merged.contains(transaction.category), !transaction.category.isEmpty {
                    merged.insert(transaction.category, at: 0)
                }
                categoryOptions = merged
            }
        }
    }

    // Human-readable list of which fields are locked.
    private var lockSummary: String {
        var parts: [String] = []
        if transaction.isCategoryLocked { parts.append("category") }
        if transaction.isMultiplierLocked { parts.append("multiplier") }
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

    private func formatMultiplier(_ value: Double) -> String {
        // Whole numbers show without decimals (“3” not “3.0”).
        if value.rounded() == value {
            return String(Int(value))
        }
        return value.formatted()
    }

    /// When travel mode changes, rewrite the multiplier draft to the card’s rate for that bucket.
    private func applyTravelModeToMultiplier(_ mode: RewardTravelMode) {
        // Closure assigned to a let for a mini switch that returns a value.
        let reward: RewardCategory = {
            switch mode {
            case .portal: return .travelPortal
            case .otherTravel: return .travelOther
            case .auto, .clear:
                return RewardCategory.forTransaction(
                    generalCategory: categoryText.isEmpty ? transaction.category : categoryText,
                    title: transaction.title
                )
            }
        }()
        let rate = benefitsProfile.rate(forCategory: reward.rawValue, on: transaction.date)
        multiplierText = formatMultiplier(rate)
    }

    // @MainActor ensures UI state updates happen on the main thread.
    // async because save may grow heavier later; currently mostly synchronous work + sleep.
    @MainActor
    private func saveEdits() async {
        // trimmingCharacters removes leading/trailing spaces users often leave in TextFields.
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        // guard else { return } validates early and exits with an error message.
        guard !trimmedCategory.isEmpty else {
            saveError = "Category can’t be empty."
            return
        }

        let normalized = multiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let multiplier = Double(normalized), multiplier >= 0 else {
            saveError = "Multiplier must be a number 0 or greater."
            return
        }

        isSaving = true
        // defer runs when the function exits (success or failure) — always clears the spinner.
        defer { isSaving = false }

        do {
            let cardScoped = scopePaymentMethod || applyToMatching

            // Local row — lock fields so future Plaid syncs don’t overwrite user choices.
            transaction.category = trimmedCategory
            transaction.multiplier = multiplier
            transaction.categoryLocked = true
            transaction.multiplierLocked = true
            transaction.paymentRail = selectedRail.rawValue
            transaction.paymentRailLocked = true
            switch rewardOverrideMode {
            case .portal:
                transaction.rewardCategoryOverride = RewardCategory.travelPortal.rawValue
            case .otherTravel:
                transaction.rewardCategoryOverride = RewardCategory.travelOther.rawValue
            case .auto, .clear:
                transaction.rewardCategoryOverride = nil
            }
            transaction.subscriptionCadenceOverride = subscriptionMode.storageValue
            transaction.overrideSource = "user"

            // Keep CreditCardPayment table + spend exclusion in sync with category choice
            syncCreditPaymentRecord(for: transaction, category: trimmedCategory)

            // Learn rule for future Plaid syncs (skip bill-payment category)
            if learn, !TransactionAnalytics.isExcludedFromSpendCategory(trimmedCategory) {
                VendorRulesStore.upsert(
                    vendor: transaction.title,
                    paymentMethod: cardScoped ? transaction.paymentMethod : nil,
                    category: trimmedCategory,
                    multiplier: multiplier
                )
            }

            var localExtra = 0
            if applyToMatching {
                localExtra = applyLocalMatching(
                    category: trimmedCategory,
                    multiplier: multiplier
                )
            }

            try modelContext.save()
            WidgetCenter.shared.reloadAllTimelines()

            // Contextual success copy based on what the user did.
            if subscriptionMode == .yearly {
                saveStatusMessage = "Saved as yearly subscription."
            } else if TransactionAnalytics.isExcludedFromSpendCategory(trimmedCategory) {
                saveStatusMessage = "Saved as Credit Card Payment (excluded from Total Spend)."
            } else if localExtra > 0 {
                saveStatusMessage = "Saved. Updated \(localExtra + 1) transactions on this card."
            } else {
                saveStatusMessage = "Saved on this device"
            }
            didSave = true
            // Brief confirmation, then hide the green banner.
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

        if TransactionAnalytics.isExcludedFromSpendCategory(category) {
            if let existing {
                existing.amount = abs(row.amount)
                existing.date = row.date
                existing.cardName = row.paymentMethod
                existing.title = row.title
            } else {
                modelContext.insert(
                    CreditCardPayment(
                        transactionId: row.transactionId,
                        amount: abs(row.amount),
                        date: row.date,
                        cardName: row.paymentMethod,
                        sourceAccount: row.paymentMethod,
                        title: row.title,
                        creditAccountId: nil,
                        institutionName: linkedAccount?.institutionName
                    )
                )
            }
        } else if let existing {
            // Reclassified away from bill-pay → drop the mirrored payment row.
            modelContext.delete(existing)
        }
    }

    // @discardableResult allows callers to ignore the returned Int without a warning.
    /// Apply category/multiplier to other transactions with the same title + card.
    @discardableResult
    private func applyLocalMatching(category: String, multiplier: Double) -> Int {
        let vendor = transaction.title
        let card = transaction.paymentMethod
        var count = 0

        for row in allTransactions {
            if row.transactionId == transaction.transactionId { continue }
            guard row.title.caseInsensitiveCompare(vendor) == .orderedSame else { continue }
            guard row.paymentMethod.caseInsensitiveCompare(card) == .orderedSame else { continue }

            row.category = category
            row.multiplier = multiplier
            row.categoryLocked = true
            row.multiplierLocked = true
            row.subscriptionCadenceOverride = subscriptionMode.storageValue
            row.overrideSource = "user"
            count += 1
        }
        return count
    }
}

#Preview {
    NavigationStack {
        Text("Open a transaction from the list")
    }
}
