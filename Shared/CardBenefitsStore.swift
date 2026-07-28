//
//  CardBenefitsStore.swift
//  Finance Wizard
//
//  User-defined rewards / benefits per credit card (or payment method).
//
//  Rates are keyed by **RewardCategory** names (Drugstores, Travel (Portal), …),
//  not general spend categories (see KnownCategory vs RewardCategory).
//

import Foundation

// MARK: - Models

enum RewardKind: String, Codable, CaseIterable, Identifiable {
    case points
    case cashback

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .points: return "Points"
        case .cashback: return "Cash back"
        }
    }

    /// Unit label next to rates (1.5x vs 3%).
    var rateSuffix: String {
        switch self {
        case .points: return "x"
        case .cashback: return "%"
        }
    }
}

struct CardBenefitItem: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        detail: String = "",
        systemImage: String? = "star.fill"
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

/// Time-boxed earn boost (rotating categories, promo windows).
struct TemporaryBoost: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var category: String
    var rate: Double
    /// Inclusive end date; nil = no expiry (treat like a normal override with a note).
    var activeThrough: Date?
    var note: String

    init(
        id: String = UUID().uuidString,
        category: String,
        rate: Double,
        activeThrough: Date? = nil,
        note: String = ""
    ) {
        self.id = id
        self.category = category
        self.rate = rate
        self.activeThrough = activeThrough
        self.note = note
    }

    func isActive(on date: Date = Date()) -> Bool {
        guard let end = activeThrough else { return true }
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let endDay = cal.startOfDay(for: end)
        return day <= endDay
    }
}

/// Partner earn at specific merchants: one display name, many title match needles.
/// Example: Amazon 5% matches `amazon.com`, `amzn.com`, `amazon fresh` — not three chips.
struct MerchantBoostPartner: Codable, Equatable, Identifiable, Hashable, Sendable {
    /// Stable key (e.g. `amazon`, `walgreens`).
    var id: String
    /// Chip / list label (e.g. `Amazon`).
    var displayName: String
    /// Lowercase substrings matched against transaction titles (longest wins across partners).
    var matchNeedles: [String]
    var rate: Double

    init(
        id: String,
        displayName: String,
        matchNeedles: [String],
        rate: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.matchNeedles = matchNeedles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        self.rate = rate
    }

    /// Convenience: one needle that is also the display id.
    init(needle: String, rate: Double) {
        let n = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pretty = n
            .split(separator: " ")
            .map { part -> String in
                let s = String(part)
                guard let first = s.first else { return s }
                return String(first).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
        self.init(id: n, displayName: pretty, matchNeedles: [n], rate: rate)
    }

    func matches(title: String) -> String? {
        let t = title.lowercased()
        return matchNeedles
            .filter { !$0.isEmpty && t.contains($0) }
            .max(by: { $0.count < $1.count })
    }
}

/// One row in the reward-category editor (always tied to a known or custom category name).
struct CategoryEarnRate: Identifiable, Equatable, Hashable {
    var id: String { category }
    var category: String
    /// Points: 1 / 1.5 / 3. Cash back: percent 1 / 2 / 3 (not 0.03).
    var rate: Double
    /// True when rate differs from the card’s default (a real “boost” or custom base).
    var isCustom: Bool
    var isKnown: Bool
}

/// Rewards profile for one linked credit account (preferred) or payment-method key.
struct CardBenefitsProfile: Codable, Equatable, Identifiable {
    /// Storage key: `account:<plaid account_id>` or `method:<payment method>`
    var id: String
    var rewardKind: RewardKind
    /// Baseline: points 1 / 1.5 / 3…; cash back as **percent** 1 / 2 / 3…
    var defaultMultiplier: Double
    /// Value of one point in cents (points cards only). 1.0 = 1¢.
    var pointValueCents: Double
    var annualFee: Double?
    var notes: String
    var benefits: [CardBenefitItem]
    /// Category name → rate override (same units as defaultMultiplier).
    var categoryMultipliers: [String: Double]
    /// Partner merchants: one label, multiple title match needles (preferred).
    var merchantBoosts: [MerchantBoostPartner]?
    /// Legacy flat needle → rate map (migrated into `merchantBoosts`).
    var merchantMultipliers: [String: Double]?
    /// Catalog product id when applied (e.g. chase_prime_visa).
    var productKey: String?
    var productDisplayName: String?
    /// Rotating / promo boosts with optional end date (decoded optional for older profiles).
    var temporaryBoosts: [TemporaryBoost]?

    static func accountKey(_ accountId: String) -> String { "account:\(accountId)" }
    static func methodKey(_ method: String) -> String { "method:\(method)" }

    var boosts: [TemporaryBoost] {
        get { temporaryBoosts ?? [] }
        set { temporaryBoosts = newValue.isEmpty ? nil : newValue }
    }

    var partnerBoosts: [MerchantBoostPartner] {
        get { merchantBoosts ?? [] }
        set { merchantBoosts = newValue.isEmpty ? nil : newValue }
    }

    static func empty(id: String) -> CardBenefitsProfile {
        CardBenefitsProfile(
            id: id,
            rewardKind: .points,
            defaultMultiplier: 1,
            pointValueCents: 1,
            annualFee: nil,
            notes: "",
            benefits: [],
            categoryMultipliers: [:],
            merchantBoosts: nil,
            merchantMultipliers: nil,
            productKey: nil,
            productDisplayName: nil,
            temporaryBoosts: nil
        )
    }

    /// Pretty label for a merchant needle (“whole foods” → “Whole Foods”).
    static func displayNameForMerchantNeedle(_ needle: String) -> String {
        needle
            .split(separator: " ")
            .map { part -> String in
                let s = String(part)
                guard let first = s.first else { return s }
                return String(first).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Fold legacy `merchantMultipliers` into structured partners (one chip per needle group later).
    mutating func migrateLegacyMerchantMultipliersIfNeeded() {
        guard let legacy = merchantMultipliers, !legacy.isEmpty else { return }
        var partners = partnerBoosts
        for (needle, rate) in legacy {
            let n = needle.lowercased()
            if partners.contains(where: { $0.matchNeedles.contains(n) || $0.id == n }) { continue }
            partners.append(MerchantBoostPartner(needle: n, rate: rate))
        }
        partnerBoosts = partners
        merchantMultipliers = nil
    }

    /// Active temporary boost for a reward category on a given day (highest rate wins).
    func activeTemporaryBoost(forCategory category: String, on date: Date = Date()) -> TemporaryBoost? {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return boosts
            .filter {
                $0.isActive(on: date)
                    && $0.category.caseInsensitiveCompare(key) == .orderedSame
            }
            .max(by: { $0.rate < $1.rate })
    }

    // MARK: - Category rates

    /// True when an override (or temp boost) meaningfully differs from the card default.
    private func rateDiffersFromDefault(_ rate: Double) -> Bool {
        abs(rate - defaultMultiplier) > 0.000_1
    }

    /// Full list for the editor: every **RewardCategory** + any custom keys.
    /// Sorted highest multiplier first (ties: A→Z).
    /// - Note: categories that only inherit the default rate are still listed here;
    ///   use `summaryCategoryRates()` for chips / compact UI so “2% cash back”
    ///   is not repeated as Dining 2%, Shopping 2%, …
    func allCategoryRates() -> [CategoryEarnRate] {
        var seen = Set<String>()
        var rows: [CategoryEarnRate] = []

        for name in RewardCategory.allNames {
            seen.insert(name.lowercased())
            let custom = lookupOverride(name)
            let isEverything = name == RewardCategory.everythingElse.rawValue
            let rate = custom ?? defaultMultiplier
            // Only “custom” when the stored/effective rate actually differs from default.
            // Everything Else represents the base even when it equals defaultMultiplier.
            let customFlag: Bool = {
                if isEverything {
                    return custom != nil && rateDiffersFromDefault(custom ?? defaultMultiplier)
                }
                return custom != nil && rateDiffersFromDefault(custom ?? defaultMultiplier)
            }()
            rows.append(
                CategoryEarnRate(
                    category: name,
                    rate: rate,
                    isCustom: customFlag,
                    isKnown: true
                )
            )
        }

        // Custom earn labels not in RewardCategory
        for (key, value) in categoryMultipliers {
            if seen.contains(key.lowercased()) { continue }
            // Skip legacy general-category keys that we migrate away from
            if KnownCategory.canonicalName(for: key) != nil,
               RewardCategory.canonicalName(for: key) == nil {
                continue
            }
            rows.append(
                CategoryEarnRate(
                    category: key,
                    rate: value,
                    isCustom: rateDiffersFromDefault(value),
                    isKnown: false
                )
            )
        }
        return rows.sorted {
            if abs($0.rate - $1.rate) > 0.0001 { return $0.rate > $1.rate }
            return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
        }
    }

    /// Compact list for chips / default editor: merchant partners, category boosts,
    /// plus a single **Everything Else** row for the default.
    /// Apple Card 2% → “Everything Else 2%” + “Walgreens 3%”, not “Drugstores 3%”.
    func summaryCategoryRates() -> [CategoryEarnRate] {
        let everything = RewardCategory.everythingElse.rawValue
        var rows: [CategoryEarnRate] = []
        var seen = Set<String>()

        // Merchant partners first — one row per partner (not per match needle)
        for partner in partnerBoosts where rateDiffersFromDefault(partner.rate) {
            let key = partner.displayName.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rows.append(
                CategoryEarnRate(
                    category: partner.displayName,
                    rate: partner.rate,
                    isCustom: true,
                    isKnown: false
                )
            )
        }

        // Category boosts / reductions (not Everything Else)
        for row in allCategoryRates() where row.isCustom && row.category != everything {
            let key = row.category.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rows.append(row)
        }

        // Active temporary boosts that aren't already covered
        for boost in boosts where boost.isActive() {
            let key = boost.category.lowercased()
            guard !seen.contains(key), key != everything.lowercased() else { continue }
            guard rateDiffersFromDefault(boost.rate) else { continue }
            seen.insert(key)
            rows.append(
                CategoryEarnRate(
                    category: boost.category,
                    rate: boost.rate,
                    isCustom: true,
                    isKnown: RewardCategory.canonicalName(for: boost.category) != nil
                )
            )
        }

        // Always surface the base as Everything Else (not as every category).
        let elseOverride = lookupOverride(everything)
        let elseRate = elseOverride ?? defaultMultiplier
        rows.append(
            CategoryEarnRate(
                category: everything,
                rate: elseRate,
                isCustom: elseOverride != nil && rateDiffersFromDefault(elseRate),
                isKnown: true
            )
        )

        return rows.sorted {
            // Everything Else always last; boosts by rate desc
            let aElse = $0.category == everything
            let bElse = $1.category == everything
            if aElse != bElse { return !aElse && bElse }
            if abs($0.rate - $1.rate) > 0.0001 { return $0.rate > $1.rate }
            return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
        }
    }

    /// Only categories with a real boost/reduction vs default (excludes Everything Else at base).
    func customCategoryRates() -> [CategoryEarnRate] {
        allCategoryRates().filter { $0.isCustom && $0.category != RewardCategory.everythingElse.rawValue }
    }

    /// Drop stored overrides that equal the default (cleanup for Apple/X Money–style flat rates).
    mutating func compactRatesMatchingDefault() {
        for (key, value) in categoryMultipliers {
            if abs(value - defaultMultiplier) < 0.000_1 {
                categoryMultipliers.removeValue(forKey: key)
            }
        }
        // Drop Everything Else override when it just restates the base
        if let v = lookupOverride(RewardCategory.everythingElse.rawValue),
           abs(v - defaultMultiplier) < 0.000_1 {
            removeRate(forCategory: RewardCategory.everythingElse.rawValue)
        }
        partnerBoosts = partnerBoosts.filter { rateDiffersFromDefault($0.rate) }
    }

    mutating func setRate(_ rate: Double?, forCategory category: String) {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Known reward categories → category map. Anything else is a merchant partner.
        if let known = RewardCategory.canonicalName(for: trimmed) {
            setCategoryRate(rate, name: known)
            return
        }
        setMerchantPartnerRate(rate, displayName: trimmed)
    }

    private mutating func setCategoryRate(_ rate: Double?, name: String) {
        guard let rate, rate >= 0 else {
            removeRate(forCategory: name)
            return
        }
        if abs(rate - defaultMultiplier) < 0.000_1 {
            categoryMultipliers.removeValue(forKey: name)
            for key in categoryMultipliers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
                categoryMultipliers.removeValue(forKey: key)
            }
            return
        }
        for key in categoryMultipliers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
            categoryMultipliers.removeValue(forKey: key)
        }
        categoryMultipliers[name] = rate
    }

    /// Update / create a partner by display name (keeps existing match needles when possible).
    mutating func setMerchantPartnerRate(_ rate: Double?, displayName: String) {
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        var list = partnerBoosts
        let idx = list.firstIndex {
            $0.displayName.caseInsensitiveCompare(label) == .orderedSame
                || $0.id.caseInsensitiveCompare(label) == .orderedSame
        }
        guard let rate, rate >= 0 else {
            if let idx { list.remove(at: idx) }
            partnerBoosts = list
            return
        }
        if abs(rate - defaultMultiplier) < 0.000_1 {
            if let idx { list.remove(at: idx) }
            partnerBoosts = list
            return
        }
        if let idx {
            list[idx].rate = rate
        } else {
            let needle = label.lowercased()
            list.append(
                MerchantBoostPartner(
                    id: needle.replacingOccurrences(of: " ", with: "_"),
                    displayName: label,
                    matchNeedles: [needle],
                    rate: rate
                )
            )
        }
        partnerBoosts = list
    }

    mutating func removeRate(forCategory category: String) {
        let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
        categoryMultipliers.removeValue(forKey: name)
        for key in categoryMultipliers.keys where key.caseInsensitiveCompare(name) == .orderedSame {
            categoryMultipliers.removeValue(forKey: key)
        }
        partnerBoosts = partnerBoosts.filter {
            $0.displayName.caseInsensitiveCompare(name) != .orderedSame
                && $0.id.caseInsensitiveCompare(name) != .orderedSame
        }
    }

    mutating func resetAllCategoryRates() {
        categoryMultipliers = [:]
        merchantBoosts = nil
        merchantMultipliers = nil
    }

    private func lookupOverride(_ category: String) -> Double? {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = categoryMultipliers[key] { return m }
        return categoryMultipliers.first {
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    /// Best merchant partner for a transaction title (longest matching needle wins).
    func matchingMerchantBoost(title: String) -> (needle: String, displayName: String, rate: Double)? {
        let t = title.lowercased()
        guard !t.isEmpty else { return nil }
        var best: (needle: String, displayName: String, rate: Double, len: Int)?
        for partner in partnerBoosts {
            guard let needle = partner.matches(title: t) else { continue }
            if best == nil || needle.count > best!.len {
                best = (needle, partner.displayName, partner.rate, needle.count)
            }
        }
        guard let best else { return nil }
        return (best.needle, best.displayName, best.rate)
    }

    /// Rate for a **reward** category name (temp boost → override → default / Everything Else).
    func rate(forCategory category: String, on date: Date = Date()) -> Double {
        if let boost = activeTemporaryBoost(forCategory: category, on: date) {
            return boost.rate
        }
        if let m = lookupOverride(category) { return m }
        // Everything Else override acts as base when set
        if let base = lookupOverride(RewardCategory.everythingElse.rawValue) {
            return base
        }
        return defaultMultiplier
    }

    /// Rate for a live transaction: **merchant partner first**, then reward category.
    func rate(
        forTransactionCategory general: String,
        title: String = "",
        on date: Date = Date()
    ) -> Double {
        if let merchant = matchingMerchantBoost(title: title) {
            return merchant.rate
        }
        let reward = RewardCategory.forTransaction(generalCategory: general, title: title)
        return rate(forCategory: reward.rawValue, on: date)
    }

    /// Bucket label for analytics / chips: merchant display name or reward category.
    func earnLabel(generalCategory: String, title: String) -> String {
        if let merchant = matchingMerchantBoost(title: title) {
            return merchant.displayName
        }
        return RewardCategory.forTransaction(generalCategory: generalCategory, title: title).rawValue
    }

    /// Alias used by analytics / sync.
    func multiplier(forCategory category: String, on date: Date = Date()) -> Double {
        rate(forCategory: category, on: date)
    }

    func multiplier(
        forTransactionCategory general: String,
        title: String = "",
        on date: Date = Date()
    ) -> Double {
        rate(forTransactionCategory: general, title: title, on: date)
    }

    /// Convert stored rate to a dollar-earn factor (cash back % → fraction; points → points per $).
    func earnFactor(forCategory category: String, on date: Date = Date()) -> Double {
        let rate = rate(forCategory: category, on: date)
        switch rewardKind {
        case .points:
            return rate
        case .cashback:
            // Prefer percent form: 3 → 0.03. Accept legacy 0.03 as-is.
            return rate > 1 ? rate / 100 : rate
        }
    }

    /// Reward units for spend: points count, or cash-back dollars.
    func rewardUnits(spendDollars: Double, category: String, on date: Date = Date()) -> Double {
        let dollars = abs(spendDollars)
        switch rewardKind {
        case .points:
            return dollars * rate(forCategory: category, on: date)
        case .cashback:
            return dollars * earnFactor(forCategory: category, on: date)
        }
    }

    /// Estimated USD value of rewards for a spend amount.
    func rewardValueUSD(spendDollars: Double, category: String, on date: Date = Date()) -> Double {
        switch rewardKind {
        case .cashback:
            return rewardUnits(spendDollars: spendDollars, category: category, on: date)
        case .points:
            let pts = rewardUnits(spendDollars: spendDollars, category: category, on: date)
            return pts * (pointValueCents / 100)
        }
    }

    func rewardUnits(
        spendDollars: Double,
        generalCategory: String,
        title: String,
        on date: Date = Date()
    ) -> Double {
        let dollars = abs(spendDollars)
        let r = rate(forTransactionCategory: generalCategory, title: title, on: date)
        switch rewardKind {
        case .points:
            return dollars * r
        case .cashback:
            let factor = r > 1 ? r / 100 : r
            return dollars * factor
        }
    }

    func rewardValueUSD(
        spendDollars: Double,
        generalCategory: String,
        title: String,
        on date: Date = Date()
    ) -> Double {
        switch rewardKind {
        case .cashback:
            return rewardUnits(spendDollars: spendDollars, generalCategory: generalCategory, title: title, on: date)
        case .points:
            let pts = rewardUnits(spendDollars: spendDollars, generalCategory: generalCategory, title: title, on: date)
            return pts * (pointValueCents / 100)
        }
    }

    /// Est. rewards value for a calendar year of the given period’s run-rate, minus annual fee.
    func annualFeePayback(periodValueUSD: Double, period: SnapshotPeriod) -> (
        projectedAnnual: Double,
        fee: Double,
        net: Double
    )? {
        guard let fee = annualFee, fee > 0 else { return nil }
        let annualized: Double = {
            switch period {
            case .week: return periodValueUSD * 52
            case .month: return periodValueUSD * 12
            case .all: return periodValueUSD // already multi-month; treat as YTD-ish
            }
        }()
        return (annualized, fee, annualized - fee)
    }

    mutating func upsertTemporaryBoost(_ boost: TemporaryBoost) {
        var list = boosts
        if let idx = list.firstIndex(where: { $0.id == boost.id }) {
            list[idx] = boost
        } else {
            list.append(boost)
        }
        boosts = list
    }

    mutating func removeTemporaryBoost(id: String) {
        boosts = boosts.filter { $0.id != id }
    }

    func formatRate(_ rate: Double) -> String {
        let formatted = rate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(formatted)\(rewardKind.rateSuffix)"
    }
}

// MARK: - Analytics helpers

enum BenefitsAnalytics {
    struct CategoryBreakdown: Identifiable {
        var id: String { category }
        var category: String
        var spend: Double
        var rate: Double
        var rewardsUnits: Double
        var rewardsValueUSD: Double
        var isCustomRate: Bool
        var transactionCount: Int
    }

    struct CardPeriodSummary: Identifiable {
        var id: String
        var displayName: String
        var account: BankAccount?
        var paymentMethods: Set<String>
        var spend: Double
        var estimatedRewardsUnits: Double
        var estimatedValueUSD: Double
        var profile: CardBenefitsProfile
        var transactionCount: Int
        var topCategories: [CategoryBreakdown]
        var categoryBreakdown: [CategoryBreakdown]
    }

    /// Credit cards + debit-reward products (X Money). Plain checking never earns points.
    static func summaries(
        accounts: [BankAccount],
        transactions: [Transaction],
        period: SnapshotPeriod,
        referenceDate: Date
    ) -> [CardPeriodSummary] {
        let spendTxs = TransactionAnalytics.spendOnly(
            TransactionAnalytics.inPeriod(transactions, period: period, referenceDate: referenceDate)
        )
        var claimed = Set<String>()
        var rows: [CardPeriodSummary] = []

        // 1) Credit cards
        for account in accounts where account.isCredit {
            let methods = matchingMethods(for: account, in: spendTxs, all: transactions)
            for m in methods { claimed.insert(m) }
            let txs = spendTxs.filter { methods.contains(TransactionAnalytics.cardName(for: $0)) }
            let profile = CardBenefitsStore.profile(
                accountId: account.accountId,
                paymentMethod: account.plaidDisplayName
            )
            rows.append(buildSummary(
                id: account.accountId,
                displayName: account.displayName,
                account: account,
                methods: methods,
                txs: txs,
                profile: profile
            ))
        }

        // 2) Debit-reward deposit accounts only (X Money) — not Chase College checking
        for account in accounts where CardBenefitsStore.hasDebitRewards(account) {
            let methods = matchingMethods(for: account, in: spendTxs, all: transactions)
            for m in methods { claimed.insert(m) }
            let txs = spendTxs.filter { tx in
                guard methods.contains(TransactionAnalytics.cardName(for: tx)) else { return false }
                // ACH does not earn on X Money
                return tx.effectivePaymentRail != .ach
            }
            let profile = CardBenefitsStore.profile(
                accountId: account.accountId,
                paymentMethod: account.plaidDisplayName
            )
            rows.append(buildSummary(
                id: account.accountId,
                displayName: account.displayName,
                account: account,
                methods: methods,
                txs: txs,
                profile: profile
            ))
        }

        // 3) Claim all other depository methods so they never look like orphan “cards”
        for account in accounts where account.isDepository {
            for m in matchingMethods(for: account, in: spendTxs, all: transactions) {
                claimed.insert(m)
            }
        }

        // 4) Orphan card-like methods (Apple Card CSV, etc.)
        let orphanMethods = Set(spendTxs.map { TransactionAnalytics.cardName(for: $0) })
            .subtracting(claimed)
            .filter { looksLikeCardMethod($0) }
            .sorted()

        for method in orphanMethods {
            let txs = spendTxs.filter { TransactionAnalytics.cardName(for: $0) == method }
            guard !txs.isEmpty else { continue }
            let profile = CardBenefitsStore.profile(accountId: nil, paymentMethod: method)
            rows.append(buildSummary(
                id: "method:\(method)",
                displayName: CardLabelStore.label(paymentMethod: method, fallback: method),
                account: nil,
                methods: [method],
                txs: txs,
                profile: profile
            ))
        }

        return rows.sorted { $0.estimatedValueUSD > $1.estimatedValueUSD }
    }

    /// Breakdown for one card’s methods + profile (uses latest profile if passed).
    static func breakdown(
        txs: [Transaction],
        profile: CardBenefitsProfile
    ) -> (spend: Double, units: Double, value: Double, categories: [CategoryBreakdown]) {
        var catSpend: [String: Double] = [:]
        var catCount: [String: Int] = [:]
        var units = 0.0
        var value = 0.0
        var spend = 0.0

        // Per-bucket rates for merchant vs category (used when aggregating)
        var bucketRate: [String: Double] = [:]

        for tx in txs {
            let dollars = abs(tx.amount)
            spend += dollars
            let general = TransactionAnalytics.categoryName(for: tx)
            let label: String = {
                if let override = tx.rewardCategoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !override.isEmpty {
                    return override
                }
                return profile.earnLabel(generalCategory: general, title: tx.title)
            }()
            catSpend[label, default: 0] += dollars
            catCount[label, default: 0] += 1

            if tx.isMultiplierLocked {
                let m = tx.multiplier
                bucketRate[label] = m
                applyLockedMultiplier(
                    dollars: dollars,
                    multiplier: m,
                    profile: profile,
                    units: &units,
                    value: &value
                )
            } else {
                let r = profile.rate(
                    forTransactionCategory: general,
                    title: tx.title,
                    on: tx.date
                )
                bucketRate[label] = r
                units += profile.rewardUnits(
                    spendDollars: dollars,
                    generalCategory: general,
                    title: tx.title,
                    on: tx.date
                )
                value += profile.rewardValueUSD(
                    spendDollars: dollars,
                    generalCategory: general,
                    title: tx.title,
                    on: tx.date
                )
            }
        }

        let categories = catSpend.map { name, s -> CategoryBreakdown in
            let isMerchant = profile.partnerBoosts.contains {
                $0.displayName.caseInsensitiveCompare(name) == .orderedSame
                    || $0.id.caseInsensitiveCompare(name) == .orderedSame
            }
            let rate = bucketRate[name]
                ?? profile.matchingMerchantBoost(title: name)?.rate
                ?? profile.rate(forCategory: name)
            let isCustom = isMerchant
                || profile.lookupIsCustom(name)
                || profile.activeTemporaryBoost(forCategory: name) != nil
            return CategoryBreakdown(
                category: name,
                spend: s,
                rate: rate,
                rewardsUnits: {
                    switch profile.rewardKind {
                    case .points: return s * rate
                    case .cashback: return s * (rate > 1 ? rate / 100 : rate)
                    }
                }(),
                rewardsValueUSD: {
                    switch profile.rewardKind {
                    case .cashback: return s * (rate > 1 ? rate / 100 : rate)
                    case .points: return s * rate * (profile.pointValueCents / 100)
                    }
                }(),
                isCustomRate: isCustom,
                transactionCount: catCount[name] ?? 0
            )
        }
        // Highest earn rate first; spend as tie-breaker
        .sorted {
            if abs($0.rate - $1.rate) > 0.0001 { return $0.rate > $1.rate }
            return $0.spend > $1.spend
        }

        return (spend, units, value, categories)
    }

    private static func applyLockedMultiplier(
        dollars: Double,
        multiplier: Double,
        profile: CardBenefitsProfile,
        units: inout Double,
        value: inout Double
    ) {
        switch profile.rewardKind {
        case .points:
            units += dollars * multiplier
            value += dollars * multiplier * (profile.pointValueCents / 100)
        case .cashback:
            let factor = multiplier > 1 ? multiplier / 100 : multiplier
            units += dollars * factor
            value += dollars * factor
        }
    }

    private static func buildSummary(
        id: String,
        displayName: String,
        account: BankAccount?,
        methods: Set<String>,
        txs: [Transaction],
        profile: CardBenefitsProfile
    ) -> CardPeriodSummary {
        let result = breakdown(txs: txs, profile: profile)
        return CardPeriodSummary(
            id: id,
            displayName: displayName,
            account: account,
            paymentMethods: methods,
            spend: result.spend,
            estimatedRewardsUnits: result.units,
            estimatedValueUSD: result.value,
            profile: profile,
            transactionCount: txs.count,
            topCategories: Array(result.categories.prefix(4)),
            categoryBreakdown: result.categories
        )
    }

    private static func matchingMethods(
        for account: BankAccount,
        in periodTxs: [Transaction],
        all: [Transaction]
    ) -> Set<String> {
        var methods = Set<String>()
        let pool = Set(all.map { TransactionAnalytics.cardName(for: $0) })
            .union(periodTxs.map { TransactionAnalytics.cardName(for: $0) })
        for method in pool where account.matchesPaymentMethod(method) {
            methods.insert(method)
        }
        methods.insert(account.plaidDisplayName)
        return methods
    }

    private static func looksLikeCardMethod(_ method: String) -> Bool {
        let m = method.lowercased()
        // Never treat deposit accounts as reward cards (e.g. "CHASE COLLEGE ···2667")
        if m.contains("checking") || m.contains("savings") || m.contains("college")
            || m.contains("money market") || m.contains("brokerage") {
            return false
        }
        if m.contains("credit") || m.contains("card") || m.contains("visa")
            || m.contains("amex") || m.contains("mastercard") || m.contains("apple card")
            || m.contains("freedom") || m.contains("sapphire") || m.contains("prime") {
            return true
        }
        return false
    }
}

private extension CardBenefitsProfile {
    func lookupIsCustom(_ category: String) -> Bool {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if categoryMultipliers[key] != nil { return true }
        return categoryMultipliers.keys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }
}

// MARK: - Persistence + Sync resolution

enum CardBenefitsStore {
    private static let key = "card.benefits.profiles.v1"
    private static let migrationVersionKey = "card.benefits.migration.v"
    private static let currentMigrationVersion = 6
    /// In-memory profiles after migration — avoid re-migrating + disk I/O on every tile.
    private static var memoryProfiles: [String: CardBenefitsProfile]?
    private static let memoryLock = NSLock()

    static func profile(accountId: String?, paymentMethod: String?) -> CardBenefitsProfile {
        ensureMigratedOnce()
        let map = cachedProfiles()
        if let accountId, !accountId.isEmpty {
            let k = CardBenefitsProfile.accountKey(accountId)
            if let p = map[k] { return p }
        }
        if let paymentMethod, !paymentMethod.isEmpty {
            let k = CardBenefitsProfile.methodKey(paymentMethod)
            if let p = map[k] { return p }
        }
        let id: String = {
            if let accountId, !accountId.isEmpty {
                return CardBenefitsProfile.accountKey(accountId)
            }
            if let paymentMethod, !paymentMethod.isEmpty {
                return CardBenefitsProfile.methodKey(paymentMethod)
            }
            return CardBenefitsProfile.methodKey("unknown")
        }()
        return CardBenefitsProfile.empty(id: id)
    }

    private static func cachedProfiles() -> [String: CardBenefitsProfile] {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        if let memoryProfiles { return memoryProfiles }
        let loaded = load()
        memoryProfiles = loaded
        return loaded
    }

    private static func invalidateMemoryCache() {
        memoryLock.lock()
        memoryProfiles = nil
        memoryLock.unlock()
    }

    /// Run heavy migrateIfNeeded once per app version, not on every profile read.
    private static func ensureMigratedOnce() {
        let defaults = UserDefaults.standard
        let v = defaults.integer(forKey: migrationVersionKey)
        guard v < currentMigrationVersion else { return }

        var map = load()
        var changed = false
        for (key, profile) in map {
            let migrated = migrateIfNeeded(profile)
            if migrated != profile {
                map[key] = migrated
                changed = true
            }
        }
        if changed {
            persist(map)
        }
        memoryLock.lock()
        memoryProfiles = map
        memoryLock.unlock()
        defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
    }

    /// Display name when a product is chosen: `"[Card name] [last 4]"`.
    static func productDisplayLabel(product: CardProductPreset, mask: String?) -> String {
        let last4 = (mask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !last4.isEmpty {
            return "\(product.displayName) \(last4)"
        }
        return product.displayName
    }

    /// Apply a catalog product onto a profile key, rename the card, and persist.
    @discardableResult
    static func applyProduct(
        _ product: CardProductPreset,
        accountId: String?,
        paymentMethod: String?,
        mask: String? = nil
    ) -> CardBenefitsProfile {
        let id: String = {
            if let accountId, !accountId.isEmpty {
                return CardBenefitsProfile.accountKey(accountId)
            }
            if let paymentMethod, !paymentMethod.isEmpty {
                return CardBenefitsProfile.methodKey(paymentMethod)
            }
            return CardBenefitsProfile.methodKey(product.id)
        }()
        let profile = CardProductCatalog.makeProfile(id: id, product: product)
        save(profile)

        // Title becomes product + last 4 so lists don't need a second "card type" line.
        let label = productDisplayLabel(product: product, mask: mask)
        CardLabelStore.setLabel(
            label,
            accountId: accountId,
            paymentMethod: paymentMethod ?? product.displayName
        )
        return profile
    }

    /// Auto-apply catalog rates for accounts that have no saved profile yet.
    /// Returns how many profiles were created.
    @discardableResult
    static func autoApplyKnownProducts(
        accounts: [BankAccount],
        paymentMethods: [String] = []
    ) -> Int {
        var applied = 0
        for account in accounts {
            let key = CardBenefitsProfile.accountKey(account.accountId)
            if load()[key] != nil { continue }
            if let product = CardProductCatalog.match(account: account) {
                applyProduct(
                    product,
                    accountId: account.accountId,
                    paymentMethod: account.plaidDisplayName,
                    mask: account.mask
                )
                applied += 1
            }
        }
        for method in paymentMethods {
            let key = CardBenefitsProfile.methodKey(method)
            if load()[key] != nil { continue }
            if let product = CardProductCatalog.match(paymentMethod: method) {
                applyProduct(product, accountId: nil, paymentMethod: method, mask: nil)
                applied += 1
            }
        }
        return applied
    }

    /// Configure BankAccount debit/ACH reward fields for X Money (and similar).
    static func applyDepositoryRailRewards(to account: BankAccount) {
        guard account.isDepository else { return }
        if account.institutionName.localizedCaseInsensitiveContains("x money")
            || account.displayName.localizedCaseInsensitiveContains("x money") {
            // Percent form consistent with Benefits cash-back rates
            account.debitRewardMultiplier = 3
            account.achRewardMultiplier = 0
        }
    }

    /// Best profile for a Plaid/local purchase (account id preferred).
    static func profile(
        accountId: String?,
        paymentMethod: String,
        accounts: [BankAccount]
    ) -> CardBenefitsProfile {
        if let accountId, !accountId.isEmpty {
            return profile(accountId: accountId, paymentMethod: paymentMethod)
        }
        if let match = BankAccount.matching(paymentMethod: paymentMethod, in: accounts) {
            return profile(accountId: match.accountId, paymentMethod: paymentMethod)
        }
        return profile(accountId: nil, paymentMethod: paymentMethod)
    }

    /// True when this depository account earns on debit (X Money, etc.).
    static func hasDebitRewards(_ account: BankAccount) -> Bool {
        guard account.isDepository else { return false }
        if (account.debitRewardMultiplier ?? 0) > 0 { return true }
        let hay = "\(account.institutionName) \(account.name) \(account.displayName)".lowercased()
        return hay.contains("x money") || hay.contains("xmoney")
    }

    /// Credit cards always; debit-reward deposit products only — never plain Chase checking.
    static func isRewardsEligible(account: BankAccount?, paymentMethod: String) -> Bool {
        if let account {
            if account.isCredit { return true }
            if hasDebitRewards(account) { return true }
            return false
        }
        let m = paymentMethod.lowercased()
        if m.contains("checking") || m.contains("savings") || m.contains("college") {
            return false
        }
        if CardProductCatalog.match(paymentMethod: paymentMethod) != nil { return true }
        return m.contains("apple card") || (m.contains("card") && !m.contains("card services"))
    }

    /// Multiplier to store on a Transaction for Sync (points x, or cash-back % as entered).
    /// Returns **0** for non-rewards accounts (plain checking) so they never earn points.
    static func resolvedMultiplier(
        accountId: String?,
        paymentMethod: String,
        category: String,
        accounts: [BankAccount],
        title: String = "",
        on date: Date = Date(),
        rewardCategoryOverride: String? = nil
    ) -> Double {
        let account = accounts.first(where: { $0.accountId == accountId })
            ?? BankAccount.matching(paymentMethod: paymentMethod, in: accounts)
        guard isRewardsEligible(account: account, paymentMethod: paymentMethod) else {
            return 0
        }
        let p = profile(
            accountId: account?.accountId ?? accountId,
            paymentMethod: paymentMethod,
            accounts: accounts
        )
        if let raw = rewardCategoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return p.rate(forCategory: raw, on: date)
        }
        return p.rate(forTransactionCategory: category, title: title, on: date)
    }

    /// Prefer this when title is known (drugstore vs personal care, etc.).
    static func resolvedMultiplier(
        accountId: String?,
        paymentMethod: String,
        generalCategory: String,
        title: String,
        accounts: [BankAccount],
        on date: Date = Date(),
        rewardCategoryOverride: String? = nil
    ) -> Double {
        let account = accounts.first(where: { $0.accountId == accountId })
            ?? BankAccount.matching(paymentMethod: paymentMethod, in: accounts)
        guard isRewardsEligible(account: account, paymentMethod: paymentMethod) else {
            return 0
        }
        let p = profile(
            accountId: account?.accountId ?? accountId,
            paymentMethod: paymentMethod,
            accounts: accounts
        )
        if let raw = rewardCategoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return p.rate(forCategory: raw, on: date)
        }
        return p.rate(forTransactionCategory: generalCategory, title: title, on: date)
    }

    static func save(_ profile: CardBenefitsProfile) {
        var map = cachedProfiles()
        var cleaned = profile
        cleaned.compactRatesMatchingDefault()
        map[cleaned.id] = cleaned
        persist(map)
        memoryLock.lock()
        memoryProfiles = map
        memoryLock.unlock()
    }

    static func allProfiles() -> [CardBenefitsProfile] {
        ensureMigratedOnce()
        return Array(cachedProfiles().values)
    }

    // MARK: - Migration

    /// - Cash-back fractions → percent  
    /// - Legacy general keys → reward keys (Personal Care → Drugstores on Freedom, etc.)  
    /// - Re-seed rates from product catalog when `productKey` is set  
    private static func migrateIfNeeded(_ profile: CardBenefitsProfile) -> CardBenefitsProfile {
        var p = profile

        // 1) Cash-back 0.03 → 3
        if p.rewardKind == .cashback {
            if p.defaultMultiplier > 0, p.defaultMultiplier <= 1 {
                p.defaultMultiplier *= 100
            }
            var rebuilt: [String: Double] = [:]
            for (k, v) in p.categoryMultipliers {
                rebuilt[k] = (v > 0 && v <= 1) ? v * 100 : v
            }
            p.categoryMultipliers = rebuilt
        }

        // 2) Generic renames (old general-category rate keys)
        let renames: [String: String] = [
            "Gas (Car)": RewardCategory.gas.rawValue,
            "Subscriptions": RewardCategory.streaming.rawValue,
            "Miscellaneous": RewardCategory.everythingElse.rawValue
        ]
        for (old, new) in renames {
            if let v = p.categoryMultipliers[old] {
                if p.categoryMultipliers[new] == nil {
                    p.categoryMultipliers[new] = v
                }
                p.categoryMultipliers.removeValue(forKey: old)
            }
        }

        // 3) Product-specific legacy mistakes from when rates shared KnownCategory names
        switch p.productKey {
        case "chase_freedom_unlimited", "chase_freedom_flex":
            // Drugstores were wrongly stored as Personal Care
            if let v = p.categoryMultipliers["Personal Care"] {
                p.categoryMultipliers[RewardCategory.drugstores.rawValue] =
                    p.categoryMultipliers[RewardCategory.drugstores.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Personal Care")
            }
            if let v = p.categoryMultipliers["Travel"] {
                p.categoryMultipliers[RewardCategory.travelPortal.rawValue] =
                    p.categoryMultipliers[RewardCategory.travelPortal.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Travel")
            }
        case "chase_prime_visa":
            if let v = p.categoryMultipliers["Shopping"], abs(v - 5) < 0.01 {
                p.categoryMultipliers[RewardCategory.amazon.rawValue] =
                    p.categoryMultipliers[RewardCategory.amazon.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Shopping")
            }
            if let v = p.categoryMultipliers["Travel"] {
                p.categoryMultipliers[RewardCategory.travelPortal.rawValue] =
                    p.categoryMultipliers[RewardCategory.travelPortal.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Travel")
            }
        case "amex_blue_cash_everyday":
            if let v = p.categoryMultipliers["Shopping"], abs(v - 3) < 0.01 {
                p.categoryMultipliers[RewardCategory.onlineRetail.rawValue] =
                    p.categoryMultipliers[RewardCategory.onlineRetail.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Shopping")
            }
        case "chase_sapphire_preferred", "chase_sapphire_reserve":
            if let v = p.categoryMultipliers["Travel"] {
                // Prefer portal bucket for the elevated rate
                p.categoryMultipliers[RewardCategory.travelPortal.rawValue] =
                    p.categoryMultipliers[RewardCategory.travelPortal.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Travel")
            }
            if let v = p.categoryMultipliers["Subscriptions"] {
                p.categoryMultipliers[RewardCategory.streaming.rawValue] =
                    p.categoryMultipliers[RewardCategory.streaming.rawValue] ?? v
                p.categoryMultipliers.removeValue(forKey: "Subscriptions")
            }
            if let v = p.categoryMultipliers["Groceries"] {
                // CSP online grocery
                if p.productKey == "chase_sapphire_preferred" {
                    p.categoryMultipliers[RewardCategory.onlineGrocery.rawValue] =
                        p.categoryMultipliers[RewardCategory.onlineGrocery.rawValue] ?? v
                    p.categoryMultipliers.removeValue(forKey: "Groceries")
                }
            }
        default:
            break
        }

        // 4) Re-seed from catalog so chips match current RewardCategory + merchant defs
        if let key = p.productKey, let product = CardProductCatalog.product(id: key) {
            p.rewardKind = product.rewardKind
            p.defaultMultiplier = product.defaultRate
            p.pointValueCents = product.pointValueCents
            p.annualFee = product.annualFee
            // Only keep rates that differ from default (flat cash-back cards stay clean)
            p.categoryMultipliers = product.categoryRates.filter {
                abs($0.value - product.defaultRate) > 0.000_1
            }
            // Merchant partners (Amazon 5% with many needles, Walgreens 3%, …)
            p.merchantBoosts = product.merchantBoosts.filter {
                abs($0.rate - product.defaultRate) > 0.000_1
            }
            if p.merchantBoosts?.isEmpty == true { p.merchantBoosts = nil }
            p.merchantMultipliers = nil
            p.productDisplayName = product.displayName
            // Refresh canned perks when empty
            if p.benefits.isEmpty {
                p.benefits = product.benefits
            }
            if p.notes.isEmpty
                || p.notes.contains("Personal Care")
                || p.notes.contains("proxy")
                || p.notes.contains("stand-in")
                || p.notes.contains("1% physical")
                || p.notes.contains("titanium")
                || p.notes.contains("Drugstores 3%")
                || p.notes.contains("Shopping@5%") {
                p.notes = product.notes
            }
        }

        // 5) Method-only Apple Card profiles without product → attach 2% product
        if p.productKey == nil,
           p.id.lowercased().contains("apple card")
            || p.id == CardBenefitsProfile.methodKey(AppleCardAccount.paymentMethod),
           let product = CardProductCatalog.product(id: AppleCardAccount.productId) {
            p = CardProductCatalog.makeProfile(id: p.id, product: product)
        }

        // 6) Legacy flat merchant map → structured partners
        p.migrateLegacyMerchantMultipliersIfNeeded()

        // 7) Legacy category proxies → drop (catalog re-seed supplies partners)
        if p.productKey == "apple_card" {
            p.categoryMultipliers.removeValue(forKey: "Drugstores")
            p.categoryMultipliers.removeValue(forKey: "Amazon / Whole Foods")
        }
        if p.productKey == "chase_prime_visa" || p.productKey == "chase_amazon_visa" {
            p.categoryMultipliers.removeValue(forKey: "Amazon / Whole Foods")
            p.categoryMultipliers.removeValue(forKey: "Shopping")
        }

        // 8) Strip leftover flat defaults
        p.compactRatesMatchingDefault()

        return p
    }

    // MARK: - Private

    private static func load() -> [String: CardBenefitsProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: CardBenefitsProfile].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func persist(_ map: [String: CardBenefitsProfile]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
