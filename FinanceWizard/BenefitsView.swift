//
//  BenefitsView.swift
//  Finance Wizard
//
//  Rewards & benefits hub. Category earn rates are first-class and feed Sync.
//

import SwiftUI
import SwiftData

struct BenefitsView: View {
    @Query private var transactions: [Transaction]
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]
    @Environment(\.modelContext) private var modelContext

    @State private var period: SnapshotPeriod = .month
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var profileEpoch = 0
    @State private var productToast: String?

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var summaries: [BenefitsAnalytics.CardPeriodSummary] {
        _ = profileEpoch
        return BenefitsAnalytics.summaries(
            accounts: accounts,
            transactions: transactions,
            period: period,
            referenceDate: referenceDate
        )
    }

    private var totalValue: Double {
        summaries.reduce(0) { $0 + $1.estimatedValueUSD }
    }

    private var totalSpend: Double {
        summaries.reduce(0) { $0 + $1.spend }
    }

    private var cardsNeedingProduct: [BenefitsAnalytics.CardPeriodSummary] {
        summaries.filter { $0.profile.productKey == nil }
    }

    /// Sum of annual fee payback nets for cards that have a fee.
    private var feePaybackRollup: (projected: Double, fees: Double, net: Double)? {
        var projected = 0.0
        var fees = 0.0
        var any = false
        for row in summaries {
            if let pb = row.profile.annualFeePayback(
                periodValueUSD: row.estimatedValueUSD,
                period: period
            ) {
                any = true
                projected += pb.projectedAnnual
                fees += pb.fee
            }
        }
        guard any else { return nil }
        return (projected, fees, projected - fees)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Estimated rewards")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                MoneyText(totalValue)
                                    .font(.title2.weight(.bold))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Card spend")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                MoneyText(totalSpend)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(periodLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        if let payback = feePaybackRollup {
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Fee payback (annualized)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    MoneyText(payback.net)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(payback.net >= 0 ? .green : .orange)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    MoneyText(payback.projected, prefix: "Rewards ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    MoneyText(payback.fees, prefix: "Fees ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Overview")
                }

                if let productToast {
                    Section {
                        Label(productToast, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }

                if !cardsNeedingProduct.isEmpty {
                    Section {
                        ForEach(cardsNeedingProduct) { row in
                            NavigationLink {
                                CardBenefitsDetailView(
                                    summary: row,
                                    period: period,
                                    referenceDate: referenceDate,
                                    onChanged: { profileEpoch += 1 },
                                    onProductApplied: { toast in
                                        showProductToast(toast)
                                    }
                                )
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        CardText(row.displayName)
                                            .font(.body.weight(.semibold))
                                        Text("Choose which card this is")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "creditcard.and.123")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    } header: {
                        Text("Action needed")
                    }
                }

                Section {
                    if summaries.isEmpty {
                        ContentUnavailableView {
                            Label("No card spend", systemImage: "gift")
                        } description: {
                            Text("Link a bank in Settings and Sync, or import an Apple Card CSV.")
                        } actions: {
                            Button("Apply known product rates") {
                                applyCatalogDefaults()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(summaries) { row in
                            NavigationLink {
                                CardBenefitsDetailView(
                                    summary: row,
                                    period: period,
                                    referenceDate: referenceDate,
                                    onChanged: { profileEpoch += 1 },
                                    onProductApplied: { toast in
                                        showProductToast(toast)
                                    }
                                )
                            } label: {
                                BenefitsCardRow(summary: row)
                            }
                        }
                    }
                } header: {
                    Text("Cards")
                }

                Section {
                    Button {
                        applyCatalogDefaults()
                    } label: {
                        Label("Apply known product rates", systemImage: "sparkles")
                    }
                } footer: {
                    Text("Fills rates for cards we recognize. Won’t change cards you’ve already set up.")
                }
            }
            .navigationTitle("Benefits")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        showTitle: true
                    )
                }
            }
            .task {
                applyCatalogDefaults()
                InstitutionLogoCache.prefetch(accounts: accounts)
            }
        }
    }

    private func showProductToast(_ message: String) {
        productToast = message
        profileEpoch += 1
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            productToast = nil
        }
    }

    private func applyCatalogDefaults() {
        // Apple Card CSV → linked credit account @ 2% base (not “Other spend”)
        AppleCardAccount.ensureIfNeeded(in: modelContext, transactions: transactions)

        let methods = Array(Set(transactions.map { TransactionAnalytics.cardName(for: $0) }))
        let n = CardBenefitsStore.autoApplyKnownProducts(
            accounts: accounts,
            paymentMethods: methods
        )
        for account in accounts {
            CardBenefitsStore.applyDepositoryRailRewards(to: account)
        }
        if n > 0 { profileEpoch += 1 }
        profileEpoch += 1 // refresh estimates after rail fields too
    }
}

// MARK: - Card row

private struct BenefitsCardRow: View {
    let summary: BenefitsAnalytics.CardPeriodSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                BankIconView(
                    paymentMethod: summary.displayName,
                    size: 40,
                    accountId: summary.account?.accountId,
                    displayName: summary.displayName,
                    institutionId: summary.account?.institutionId,
                    institutionName: summary.account?.institutionName
                        ?? (summary.displayName.localizedCaseInsensitiveContains("apple") ? "Apple Card" : nil)
                )
                VStack(alignment: .leading, spacing: 4) {
                    CardText(summary.displayName)
                        .font(.body.weight(.semibold))
                    // Product type is baked into displayName ("Freedom Unlimited 1234") when chosen.
                    Text("\(summary.transactionCount) purchases · \(summary.profile.rewardKind.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(summary.estimatedValueUSD)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(rewardUnitsLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let pb = summary.profile.annualFeePayback(
                        periodValueUSD: summary.estimatedValueUSD,
                        period: .month
                    ) {
                        Text(pb.net >= 0 ? "Fee ok" : "Fee gap")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(pb.net >= 0 ? .green : .orange)
                    }
                }
            }

            if summary.profile.productKey == nil {
                Text("Choose a card type")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }

            // Compact rates: boosts + Everything Else (never “Dining 2%, Shopping 2%, …”)
            let rateChips = summary.profile.summaryCategoryRates()
            let temps = (summary.profile.temporaryBoosts ?? []).filter {
                $0.isActive() && abs($0.rate - summary.profile.defaultMultiplier) > 0.0001
            }
            if !rateChips.isEmpty || !temps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(temps.prefix(3)), id: \.id) { boost in
                            Text("⏱ \(boost.category) \(summary.profile.formatRate(boost.rate))")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.indigo.opacity(0.18))
                                .foregroundStyle(.indigo)
                                .clipShape(Capsule())
                        }
                        ForEach(Array(rateChips.prefix(8)), id: \.id) { row in
                            let isBase = row.category == RewardCategory.everythingElse.rawValue
                                && !row.isCustom
                            Text("\(isBase ? "Everything Else" : row.category) \(summary.profile.formatRate(row.rate))")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    isBase
                                    ? Color.secondary.opacity(0.14)
                                    : CategoryStyle.color(forReward: row.category).opacity(0.18)
                                )
                                .foregroundStyle(
                                    isBase
                                    ? Color.secondary
                                    : CategoryStyle.color(forReward: row.category)
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var rewardUnitsLabel: String {
        let u = summary.estimatedRewardsUnits
        switch summary.profile.rewardKind {
        case .points:
            return "\(u.formatted(.number.precision(.fractionLength(0...0)))) pts"
        case .cashback:
            return "cash back"
        }
    }
}

// MARK: - Detail

struct CardBenefitsDetailView: View {
    let summary: BenefitsAnalytics.CardPeriodSummary
    let period: SnapshotPeriod
    let referenceDate: Date
    var onChanged: () -> Void
    var onProductApplied: ((String) -> Void)?

    @Query private var transactions: [Transaction]
    @State private var profile: CardBenefitsProfile
    @State private var headerDisplayName: String
    @State private var rateDrafts: [String: String] = [:]
    @State private var newCustomCategory = ""
    @State private var newCustomRate = ""
    @State private var newBenefitTitle = ""
    @State private var newBenefitDetail = ""
    @State private var didSave = false
    /// When false (default): boosts + Everything Else only. When true: every reward category.
    @State private var showAllCategories = false
    @State private var productBanner: String?
    // Temporary / rotating boost draft fields
    @State private var tempCategory: String = RewardCategory.gas.rawValue
    @State private var tempRateText: String = "5"
    @State private var tempThrough: Date = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var tempNote: String = ""
    @State private var tempHasEndDate = true

    init(
        summary: BenefitsAnalytics.CardPeriodSummary,
        period: SnapshotPeriod,
        referenceDate: Date,
        onChanged: @escaping () -> Void,
        onProductApplied: ((String) -> Void)? = nil
    ) {
        self.summary = summary
        self.period = period
        self.referenceDate = referenceDate
        self.onChanged = onChanged
        self.onProductApplied = onProductApplied
        _profile = State(initialValue: summary.profile)
        _headerDisplayName = State(initialValue: summary.displayName)
    }

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var periodTxs: [Transaction] {
        TransactionAnalytics.spendOnly(
            TransactionAnalytics.inPeriod(transactions, period: period, referenceDate: referenceDate)
        ).filter { summary.paymentMethods.contains(TransactionAnalytics.cardName(for: $0)) }
    }

    private var live: (spend: Double, units: Double, value: Double, categories: [BenefitsAnalytics.CategoryBreakdown]) {
        BenefitsAnalytics.breakdown(txs: periodTxs, profile: profile)
    }

    private var editorRows: [CategoryEarnRate] {
        if showAllCategories {
            return profile.allCategoryRates()
        }
        // Compact: real boosts + single Everything Else for the default rate
        return profile.summaryCategoryRates()
    }

    var body: some View {
        List {
            Section {
                InstitutionLogoHeader(
                    displayName: headerDisplayName,
                    institutionId: summary.account?.institutionId,
                    institutionName: summary.account?.institutionName,
                    mask: summary.account?.mask
                )
                .listRowBackground(Color.clear)
            }

            if let productBanner {
                Section {
                    Label(productBanner, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }
            }

            // MARK: Period totals
            Section {
                LabeledContent("Spend") {
                    MoneyText(live.spend)
                }
                LabeledContent("Est. value") {
                    MoneyText(live.value)
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                }
                if profile.rewardKind == .points {
                    LabeledContent("Est. points") {
                        Text(live.units.formatted(.number.precision(.fractionLength(0...0))))
                    }
                }
                if let pb = profile.annualFeePayback(periodValueUSD: live.value, period: period) {
                    LabeledContent("Annualized rewards") {
                        MoneyText(pb.projectedAnnual)
                    }
                    LabeledContent("Annual fee") {
                        MoneyText(pb.fee)
                    }
                    LabeledContent("Fee payback") {
                        MoneyText(pb.net)
                            .foregroundStyle(pb.net >= 0 ? .green : .orange)
                            .fontWeight(.semibold)
                    }
                }
                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("This period")
            }

            // MARK: Category breakdown (from actual spend)
            if !live.categories.isEmpty {
                Section {
                    ForEach(live.categories) { row in
                        HStack(spacing: 10) {
                            Image(systemName: CategoryStyle.symbolName(forReward: row.category))
                                .foregroundStyle(CategoryStyle.color(forReward: row.category))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.category)
                                    .font(.body.weight(.medium))
                                HStack(spacing: 4) {
                                    Text("\(row.transactionCount) ·")
                                    MoneyText(row.spend, suffix: " spend")
                                }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(profile.formatRate(row.rate))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(row.isCustomRate ? CategoryStyle.color(forReward: row.category) : .secondary)
                                MoneyText(row.rewardsValueUSD)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                } header: {
                    Text("By category · \(periodLabel)")
                }
            }

            // MARK: Product preset
            Section {
                if profile.productKey == nil {
                    Text("Pick your card so we can load the right earn rates.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let name = profile.productDisplayName {
                    LabeledContent("Product") {
                        Text(name)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Menu {
                    ForEach(CardProductCatalog.all) { product in
                        Button {
                            applyProduct(product)
                        } label: {
                            Text("\(product.issuer): \(product.displayName)")
                        }
                    }
                } label: {
                    Label(
                        profile.productKey == nil ? "Choose card…" : "Change card…",
                        systemImage: "creditcard.and.123"
                    )
                }

                if needsProductPick {
                    Text("This looks like a Chase Ultimate Rewards card — pick Freedom Unlimited, Flex, Sapphire Preferred, or Reserve.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Card")
            }

            // MARK: Temporary / rotating boosts
            TemporaryBoostsEditorSection(
                profile: $profile,
                tempCategory: $tempCategory,
                tempRateText: $tempRateText,
                tempThrough: $tempThrough,
                tempNote: $tempNote,
                tempHasEndDate: $tempHasEndDate,
                onAdd: addTemporaryBoost
            )

            // MARK: Earn type + default
            Section {
                Picker("Reward type", selection: $profile.rewardKind) {
                    ForEach(RewardKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                HStack {
                    Text(profile.rewardKind == .points ? "Default rate" : "Default cash back")
                    Spacer()
                    TextField(
                        profile.rewardKind == .points ? "1" : "1",
                        value: $profile.defaultMultiplier,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    Text(profile.rewardKind.rateSuffix)
                        .foregroundStyle(.secondary)
                }

                if profile.rewardKind == .points {
                    HStack {
                        Text("Point value")
                        Spacer()
                        TextField("1", value: $profile.pointValueCents, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("¢")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Annual fee")
                    Spacer()
                    TextField(
                        "0",
                        value: $profile.annualFee,
                        format: .currency(code: "USD").precision(.fractionLength(0...2))
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                }
            } header: {
                Text("Earn rates")
            }

            // MARK: Reward categories editor (not general Transaction categories)
            Section {
                Toggle("Show all reward categories", isOn: $showAllCategories)

                if editorRows.isEmpty {
                    Text("No rates to show.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(editorRows) { row in
                        CategoryRateEditorRow(
                            category: row.category,
                            hint: categoryEditorHint(for: row),
                            rateText: binding(for: row.category, current: row.rate),
                            isCustom: row.isCustom,
                            rateSuffix: profile.rewardKind.rateSuffix,
                            onCommit: { commitRate(for: row.category) },
                            onReset: {
                                profile.removeRate(forCategory: row.category)
                                rateDrafts[row.category] = formatRateDraft(profile.defaultMultiplier)
                            }
                        )
                    }
                }

                HStack {
                    TextField("Dining or Amazon: amazon.com, amzn", text: $newCustomCategory)
                    TextField(profile.rewardKind == .points ? "3" : "3", text: $newCustomRate)
                        .keyboardType(.decimalPad)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Button("Add") { addCustomCategory() }
                        .disabled(newCustomCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !profile.categoryMultipliers.isEmpty {
                    Button("Reset all category boosts", role: .destructive) {
                        profile.resetAllCategoryRates()
                        rateDrafts = [:]
                        seedRateDrafts()
                    }
                }
            } header: {
                Text("Categories & partners")
            }

            // MARK: Perks
            Section {
                if profile.benefits.isEmpty {
                    Text("No perks yet — pick a card or add one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profile.benefits) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: item.systemImage ?? "star.fill")
                                .font(.body.weight(.medium))
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                profile.benefits.removeAll { $0.id == item.id }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                TextField("Title", text: $newBenefitTitle)
                TextField("Details (optional)", text: $newBenefitDetail)
                Button("Add perk") { addBenefit() }
                    .disabled(newBenefitTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Perks & benefits")
            }

            Section {
                TextField("Notes", text: $profile.notes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Notes")
            }

            Section {
                Button("Save benefits profile") {
                    // Commit any in-progress rate fields
                    for row in profile.allCategoryRates() {
                        commitRate(for: row.category)
                    }
                    save()
                }
                .fontWeight(.semibold)
                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Benefits")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            seedRateDrafts()
            // Soft-match product if empty
            if profile.productKey == nil, let account = summary.account,
               let product = CardProductCatalog.match(account: account) {
                applyProduct(product)
            } else if profile.productKey == nil,
                      let product = CardProductCatalog.match(paymentMethod: summary.displayName) {
                applyProduct(product)
            }
        }
        .onChange(of: profile.defaultMultiplier) { _, newDefault in
            for row in profile.allCategoryRates() where !row.isCustom {
                rateDrafts[row.category] = formatRateDraft(newDefault)
            }
        }
    }

    private var needsProductPick: Bool {
        guard profile.productKey == nil, let account = summary.account else { return false }
        let hay = "\(account.officialName ?? "") \(account.name)".lowercased()
        return hay.contains("ultimate rewards")
    }

    private func applyProduct(_ product: CardProductPreset) {
        let id = profile.id
        var next = CardProductCatalog.makeProfile(id: id, product: product)
        // Keep user notes if they already typed something unique
        if !profile.notes.isEmpty, profile.productKey != nil {
            next.notes = profile.notes
        }
        // Preserve temporary boosts across product swap
        next.temporaryBoosts = profile.temporaryBoosts
        profile = next
        rateDrafts = [:]
        seedRateDrafts()

        // Rename card → "[Card product] [last 4]" so the product isn't a second subtitle line.
        let label = CardBenefitsStore.productDisplayLabel(
            product: product,
            mask: summary.account?.mask
        )
        if let account = summary.account {
            CardLabelStore.setLabel(
                label,
                accountId: account.accountId,
                paymentMethod: account.plaidDisplayName
            )
        } else if let method = summary.paymentMethods.sorted().first {
            CardLabelStore.setLabel(label, paymentMethod: method)
        } else {
            CardLabelStore.setLabel(label, paymentMethod: summary.displayName)
        }
        headerDisplayName = label

        // Also set X Money rails when applicable
        if product.id == "x_money", let account = summary.account {
            CardBenefitsStore.applyDepositoryRailRewards(to: account)
        }
        CardBenefitsStore.save(profile)

        let toast = "Renamed to \(label) · rates applied · Sync to refresh unlocks"
        productBanner = toast
        onProductApplied?(toast)
        onChanged()
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            productBanner = nil
        }
    }

    private func addTemporaryBoost() {
        let rateText = tempRateText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let rate = Double(rateText), rate >= 0 else { return }
        let boost = TemporaryBoost(
            category: tempCategory,
            rate: rate,
            activeThrough: tempHasEndDate ? tempThrough : nil,
            note: tempNote.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        profile.upsertTemporaryBoost(boost)
        tempNote = ""
    }

    // MARK: - Rate field bindings

    private func seedRateDrafts() {
        for row in profile.allCategoryRates() {
            rateDrafts[row.category] = formatRateDraft(row.rate)
        }
        // Compact summary rows (Everything Else) always have a draft too
        for row in profile.summaryCategoryRates() {
            rateDrafts[row.category] = formatRateDraft(row.rate)
        }
    }

    private func categoryEditorHint(for row: CategoryEarnRate) -> String? {
        if row.category == RewardCategory.everythingElse.rawValue {
            return "Base rate for everything without a boost."
        }
        if RewardCategory.canonicalName(for: row.category) == nil {
            return "Partner rate for this merchant."
        }
        return RewardCategory.allCases.first { $0.rawValue == row.category }?.editorHint
    }

    private func addCustomCategory() {
        let name = newCustomCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let rateText = newCustomRate.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !name.isEmpty, let rate = Double(rateText), rate >= 0 else { return }
        // Known reward categories → category map; free text → merchant partner
        // (use a comma-separated list of match needles after the name, e.g. "Amazon: amazon.com, amzn.com")
        if RewardCategory.canonicalName(for: name) != nil {
            profile.setRate(rate, forCategory: name)
            rateDrafts[name] = formatRateDraft(rate)
        } else if name.contains(":") {
            let parts = name.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let label = parts[0]
            let needles = (parts.count > 1 ? parts[1] : label)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            var list = profile.partnerBoosts
            list.removeAll { $0.displayName.caseInsensitiveCompare(label) == .orderedSame }
            list.append(
                MerchantBoostPartner(
                    id: label.lowercased().replacingOccurrences(of: " ", with: "_"),
                    displayName: label,
                    matchNeedles: needles.isEmpty ? [label.lowercased()] : needles,
                    rate: rate
                )
            )
            profile.partnerBoosts = list
            rateDrafts[label] = formatRateDraft(rate)
        } else {
            profile.setRate(rate, forCategory: name)
            rateDrafts[name] = formatRateDraft(rate)
        }
        newCustomCategory = ""
        newCustomRate = ""
    }

    private func formatRateDraft(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func binding(for category: String, current: Double) -> Binding<String> {
        Binding(
            get: {
                rateDrafts[category] ?? formatRateDraft(current)
            },
            set: { rateDrafts[category] = $0 }
        )
    }

    private func commitRate(for category: String) {
        let text = (rateDrafts[category] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        // Everything Else is the base rate — edit defaultMultiplier, not a per-category stamp.
        if category == RewardCategory.everythingElse.rawValue {
            if text.isEmpty {
                rateDrafts[category] = formatRateDraft(profile.defaultMultiplier)
                return
            }
            guard let value = Double(text), value >= 0 else { return }
            profile.defaultMultiplier = value
            profile.removeRate(forCategory: category)
            profile.compactRatesMatchingDefault()
            rateDrafts[category] = formatRateDraft(value)
            // Keep non-custom drafts in sync with new base
            for row in profile.allCategoryRates() where !row.isCustom {
                rateDrafts[row.category] = formatRateDraft(value)
            }
            return
        }
        if text.isEmpty {
            profile.removeRate(forCategory: category)
            rateDrafts[category] = formatRateDraft(profile.defaultMultiplier)
            return
        }
        guard let value = Double(text), value >= 0 else { return }
        profile.setRate(value, forCategory: category)
        // Merchants aren't reward categories — keep the draft as entered.
        if RewardCategory.canonicalName(for: category) != nil {
            rateDrafts[category] = formatRateDraft(profile.rate(forCategory: category))
        } else {
            rateDrafts[category] = formatRateDraft(value)
        }
    }

    private func addBenefit() {
        let title = newBenefitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        profile.benefits.append(
            CardBenefitItem(
                title: title,
                detail: newBenefitDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        newBenefitTitle = ""
        newBenefitDetail = ""
    }

    private func save() {
        CardBenefitsStore.save(profile)
        didSave = true
        onChanged()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didSave = false
        }
    }
}

// MARK: - Category rate row

private struct CategoryRateEditorRow: View {
    let category: String
    var hint: String? = nil
    @Binding var rateText: String
    let isCustom: Bool
    let rateSuffix: String
    var onCommit: () -> Void
    var onReset: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: CategoryStyle.symbolName(forReward: category))
                .foregroundStyle(CategoryStyle.color(forReward: category))
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(category)
                    .font(.body)
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isCustom {
                    Text("Boost")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CategoryStyle.color(forReward: category))
                } else {
                    Text("Default")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                TextField("1", text: $rateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onSubmit(onCommit)
                Text(rateSuffix)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
                if isCustom {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Reset to default")
                }
            }
            .padding(.top, 2)
        }
        .onChange(of: rateText) { _, _ in
            onCommit()
        }
    }
}

// MARK: - Temporary boosts editor (split out so the detail body type-checks)

private struct TemporaryBoostsEditorSection: View {
    @Binding var profile: CardBenefitsProfile
    @Binding var tempCategory: String
    @Binding var tempRateText: String
    @Binding var tempThrough: Date
    @Binding var tempNote: String
    @Binding var tempHasEndDate: Bool
    var onAdd: () -> Void

    private var boosts: [TemporaryBoost] {
        profile.temporaryBoosts ?? []
    }

    var body: some View {
        Section {
            if boosts.isEmpty {
                Text("No temporary boosts yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(boosts, id: \.id) { boost in
                    TemporaryBoostRow(
                        boost: boost,
                        rateLabel: profile.formatRate(boost.rate),
                        onRemove: { profile.removeTemporaryBoost(id: boost.id) }
                    )
                }
            }

            Picker("Category", selection: $tempCategory) {
                ForEach(RewardCategory.allCases) { rc in
                    Text(rc.rawValue).tag(rc.rawValue)
                }
            }
            HStack {
                Text("Rate")
                Spacer()
                TextField("5", text: $tempRateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                Text(profile.rewardKind.rateSuffix)
                    .foregroundStyle(.secondary)
            }
            Toggle("Ends on date", isOn: $tempHasEndDate)
            if tempHasEndDate {
                DatePicker("Active through", selection: $tempThrough, displayedComponents: .date)
            }
            TextField("Note (optional)", text: $tempNote)
            Button("Add temporary boost", action: onAdd)
                .disabled(tempRateText.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Temporary boosts")
        }
    }
}

private struct TemporaryBoostRow: View {
    let boost: TemporaryBoost
    let rateLabel: String
    var onRemove: () -> Void

    private var statusLine: String {
        guard let end = boost.activeThrough else { return "No end date" }
        let date = end.formatted(date: .abbreviated, time: .omitted)
        return boost.isActive() ? "Active through \(date)" : "Ended \(date)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(boost.category)
                    .font(.body.weight(.medium))
                Spacer()
                Text(rateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
            }
            HStack {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(
                        (boost.isActive() || boost.activeThrough == nil)
                        ? Color.secondary
                        : Color.orange
                    )
                if !boost.note.isEmpty {
                    Text("· \(boost.note)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

#Preview {
    BenefitsView()
        .modelContainer(
            for: [Transaction.self, BankAccount.self, CreditCardPayment.self],
            inMemory: true
        )
}
