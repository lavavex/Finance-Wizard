//
//  BenefitsAnalytics.swift
//  Finance Wizard
//
//  Card rewards totals and per-category breakdown for the Benefits tab.
//

import Foundation

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
    /// - Parameter includeCategoryBreakdown: full per-category rows (detail). List uses `false`.
    static func summaries(
        accounts: [BankAccount],
        transactions: [Transaction],
        period: SnapshotPeriod,
        referenceDate: Date,
        includeCategoryBreakdown: Bool = true
    ) -> [CardPeriodSummary] {
        let spendTxs = TransactionAnalytics.spendOnly(
            TransactionAnalytics.inPeriod(transactions, period: period, referenceDate: referenceDate)
        )

        // One pass: group period spend by payment method
        var txsByMethod: [String: [Transaction]] = [:]
        txsByMethod.reserveCapacity(32)
        for tx in spendTxs {
            let method = TransactionAnalytics.cardName(for: tx)
            txsByMethod[method, default: []].append(tx)
        }
        let allMethods = Set(txsByMethod.keys)
            .union(transactions.lazy.map { TransactionAnalytics.cardName(for: $0) })

        var claimed = Set<String>()
        var rows: [CardPeriodSummary] = []

        // 1) Credit cards
        for account in accounts where account.isCredit {
            let methods = matchingMethods(for: account, pool: allMethods)
            for m in methods { claimed.insert(m) }
            let txs = txsForMethods(methods, in: txsByMethod)
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
                profile: profile,
                includeCategoryBreakdown: includeCategoryBreakdown
            ))
        }

        // 2) Debit-reward deposit accounts only (X Money) — not Chase College checking
        for account in accounts where CardBenefitsStore.hasDebitRewards(account) {
            let methods = matchingMethods(for: account, pool: allMethods)
            for m in methods { claimed.insert(m) }
            let txs = txsForMethods(methods, in: txsByMethod).filter {
                // ACH does not earn on X Money
                $0.effectivePaymentRail != .ach
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
                profile: profile,
                includeCategoryBreakdown: includeCategoryBreakdown
            ))
        }

        // 3) Claim all other depository methods so they never look like orphan “cards”
        for account in accounts where account.isDepository {
            for m in matchingMethods(for: account, pool: allMethods) {
                claimed.insert(m)
            }
        }

        // 4) Orphan card-like methods (Apple Card CSV, etc.)
        let orphanMethods = allMethods
            .subtracting(claimed)
            .filter { looksLikeCardMethod($0) }
            .sorted()

        for method in orphanMethods {
            let txs = txsByMethod[method] ?? []
            guard !txs.isEmpty else { continue }
            let profile = CardBenefitsStore.profile(accountId: nil, paymentMethod: method)
            rows.append(buildSummary(
                id: "method:\(method)",
                displayName: CardLabelStore.label(paymentMethod: method, fallback: method),
                account: nil,
                methods: [method],
                txs: txs,
                profile: profile,
                includeCategoryBreakdown: includeCategoryBreakdown
            ))
        }

        return rows.sorted { $0.estimatedValueUSD > $1.estimatedValueUSD }
    }

    private static func txsForMethods(
        _ methods: Set<String>,
        in txsByMethod: [String: [Transaction]]
    ) -> [Transaction] {
        var out: [Transaction] = []
        for m in methods {
            if let chunk = txsByMethod[m] {
                out.append(contentsOf: chunk)
            }
        }
        return out
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
        profile: CardBenefitsProfile,
        includeCategoryBreakdown: Bool
    ) -> CardPeriodSummary {
        if includeCategoryBreakdown {
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
        // List path: totals only — skip per-category aggregation.
        let result = totalsOnly(txs: txs, profile: profile)
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
            topCategories: [],
            categoryBreakdown: []
        )
    }

    /// Rewards totals without building category rows (Benefits list / tab switch).
    private static func totalsOnly(
        txs: [Transaction],
        profile: CardBenefitsProfile
    ) -> (spend: Double, units: Double, value: Double) {
        var units = 0.0
        var value = 0.0
        var spend = 0.0
        for tx in txs {
            let dollars = abs(tx.amount)
            spend += dollars
            if tx.isMultiplierLocked {
                applyLockedMultiplier(
                    dollars: dollars,
                    multiplier: tx.multiplier,
                    profile: profile,
                    units: &units,
                    value: &value
                )
            } else {
                let general = TransactionAnalytics.categoryName(for: tx)
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
        return (spend, units, value)
    }

    private static func matchingMethods(
        for account: BankAccount,
        pool: Set<String>
    ) -> Set<String> {
        var methods = Set<String>()
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

extension CardBenefitsProfile {
    /// Used by BenefitsAnalytics category rows.
    func lookupIsCustom(_ category: String) -> Bool {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if categoryMultipliers[key] != nil { return true }
        return categoryMultipliers.keys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }
}
