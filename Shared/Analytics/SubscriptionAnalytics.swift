//
//  SubscriptionAnalytics.swift
//  Finance Wizard
//
//  Detects likely *subscriptions* and repeating bills — not “I buy coffee here a lot.”
//  Fixed-price subs need near-identical amounts + name/cadence signals.
//  Variable bills (phone, electric) group by vendor when cadence is regular, or when
//  the user marks a charge as weekly/monthly/yearly (amount need not match).
//  Monthly/weekly with no charge in 3+ months → treated as cancelled (hidden).
//

import Foundation

/// How often a subscription is expected to charge.
enum SubscriptionCadence: String, CaseIterable, Identifiable, Sendable {
    case weekly
    case monthly
    case yearly

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

/// One detected (or user-declared) recurring charge group.
struct SubscriptionCandidate: Identifiable, Sendable {
    /// Composite id so two Netflix amounts or cadences do not collide in a list.
    var id: String { normalizedVendor + "|" + String(format: "%.2f", typicalAmount) + "|" + cadence.rawValue }
    var displayVendor: String
    var normalizedVendor: String
    var typicalAmount: Double
    var cadence: SubscriptionCadence
    /// Rough monthly burn (weekly × ~4.33, yearly / 12, monthly as-is).
    var estimatedMonthly: Double
    var occurrenceCount: Int
    var lastDate: Date
    var paymentMethods: [String]
    var sampleTransactionIds: [String]
    /// Why we think this is a subscription (for UI/debug).
    var confidenceNote: String
    /// True when cadence came from a user declaration on a transaction.
    var isUserDeclared: Bool
    /// True when clustered charges are not all the same price (phone / electric).
    var amountVaries: Bool
}

/// Lightweight Sendable row for subscription detection off the main actor.
/// Copies plain values from a Transaction so background tasks never touch SwiftData models.
struct SubscriptionTxSnapshot: Sendable, Hashable {
    let transactionId: String
    let title: String
    let amount: Double
    let date: Date
    let category: String
    let paymentMethod: String
    let subscriptionCadenceOverride: String?

    init(transaction: Transaction) {
        transactionId = transaction.transactionId
        title = transaction.title
        amount = transaction.amount
        date = transaction.date
        category = transaction.category
        paymentMethod = transaction.paymentMethod
        subscriptionCadenceOverride = transaction.subscriptionCadenceOverride
    }

    /// User-picked cadence if the override string is weekly/monthly/yearly.
    nonisolated var declaredSubscriptionCadence: SubscriptionCadence? {
        guard let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty, raw != "none", raw != "auto" else {
            return nil
        }
        return SubscriptionCadence(rawValue: raw)
    }

    /// User explicitly said “this is not a subscription.”
    nonisolated var isDeclaredNotSubscription: Bool {
        let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "none"
    }

    nonisolated var cardName: String {
        paymentMethod.isEmpty ? "Unknown" : paymentMethod
    }
}

/// Subscription detection and rollup math. Snapshot methods are `nonisolated`
/// so they can run inside `Task.detached` under default MainActor isolation.
enum SubscriptionAnalytics {
    /// Months without a charge before we treat a monthly/weekly sub as cancelled.
    nonisolated static let monthlyCancelAfterMonths = 3
    /// Months without a charge before a yearly sub is treated as cancelled (~1 year + grace).
    nonisolated static let yearlyCancelAfterMonths = 15

    /// Snapshot SwiftData models on the main actor, then call `detect(snapshots:)`.
    static func snapshots(from transactions: [Transaction]) -> [SubscriptionTxSnapshot] {
        transactions.map { SubscriptionTxSnapshot(transaction: $0) }
    }

    /// Active subscriptions only (cancelled / stale monthly excluded).
    static func detect(
        in transactions: [Transaction],
        now: Date = Date(),
        lookbackDays: Int = 400
    ) -> [SubscriptionCandidate] {
        detect(
            snapshots: snapshots(from: transactions),
            now: now,
            lookbackDays: lookbackDays
        )
    }

    /// Preferred for background work — pure value types, no SwiftData.
    nonisolated static func detect(
        snapshots: [SubscriptionTxSnapshot],
        now: Date = Date(),
        lookbackDays: Int = 400
    ) -> [SubscriptionCandidate] {
        detectAll(snapshots: snapshots, now: now, lookbackDays: lookbackDays)
            .filter { isActive($0, now: now) }
    }

    /// All candidates including stale (for debugging); UI uses `detect`.
    static func detectAll(
        in transactions: [Transaction],
        now: Date = Date(),
        lookbackDays: Int = 400
    ) -> [SubscriptionCandidate] {
        detectAll(
            snapshots: snapshots(from: transactions),
            now: now,
            lookbackDays: lookbackDays
        )
    }

    /// Core pipeline: filter spend → declared subs → vendor clusters → amount clusters → cadence.
    nonisolated static func detectAll(
        snapshots: [SubscriptionTxSnapshot],
        now: Date = Date(),
        lookbackDays: Int = 400
    ) -> [SubscriptionCandidate] {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -lookbackDays, to: now) else { return [] }

        let spendAll = snapshots
            .filter { !TransactionAnalytics.isExcludedFromSpendCategory($0.category) }
            .filter { abs($0.amount) >= 0.99 }

        // Auto-detect pool: recent window, skip habits / retail / explicit "not a sub"
        let autoPool = spendAll
            .filter { $0.date >= start }
            .filter { !isHabitCategory($0.category) }
            .filter { !looksLikeRetailHabit(title: $0.title) }
            .filter { !$0.isDeclaredNotSubscription }

        var results: [SubscriptionCandidate] = []
        var claimedKeys = Set<String>()
        var claimedVendors = Set<String>()

        // 1) User-declared subscriptions (yearly etc.) — even single charges / habit categories
        for declared in collectDeclaredCandidates(from: spendAll, now: now) {
            claimedKeys.insert(candidateKey(declared))
            claimedVendors.insert(declared.normalizedVendor)
            results.append(declared)
        }

        // 2) Heuristic auto-detect: group by normalized merchant name
        var byVendor: [String: [SubscriptionTxSnapshot]] = [:]
        for tx in autoPool {
            let key = normalizeVendor(tx.title)
            guard key.count >= 3 else { continue }
            byVendor[key, default: []].append(tx)
        }

        for (key, rows) in byVendor {
            if claimedVendors.contains(key) { continue }
            let sorted = rows.sorted { $0.date < $1.date }
            var addedForVendor = false
            for cluster in exactAmountClusters(sorted) {
                if let candidate = candidateFromCluster(
                    key: key,
                    cluster: cluster,
                    requireTightAmount: true,
                    now: now
                ) {
                    let ck = candidateKey(candidate)
                    guard !claimedKeys.contains(ck) else { continue }
                    claimedKeys.insert(ck)
                    results.append(candidate)
                    addedForVendor = true
                }
            }
            // Phone / electric / other bills: same vendor, regular cadence, amount may change.
            let billLike = sorted.contains { looksLikeBillCategory($0.category) }
                || sorted.contains { looksLikeSubscriptionName($0.title) }
            if !addedForVendor, billLike,
               let candidate = candidateFromCluster(
                    key: key,
                    cluster: sorted,
                    requireTightAmount: false,
                    now: now
               ) {
                let ck = candidateKey(candidate)
                if !claimedKeys.contains(ck) {
                    claimedKeys.insert(ck)
                    results.append(candidate)
                }
            }
        }

        return results.sorted { $0.estimatedMonthly > $1.estimatedMonthly }
    }

    /// Monthly/weekly: no charge in 3+ months → cancelled.
    /// Yearly: no charge in 15+ months → cancelled.
    nonisolated static func isActive(_ candidate: SubscriptionCandidate, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        let months: Int = {
            switch candidate.cadence {
            case .monthly, .weekly: return monthlyCancelAfterMonths
            case .yearly: return yearlyCancelAfterMonths
            }
        }()
        guard let cutoff = cal.date(byAdding: .month, value: -months, to: now) else {
            return true
        }
        return candidate.lastDate >= cutoff
    }

    /// Sum of estimated monthly costs across candidates.
    nonisolated static func totalMonthlyBurn(_ items: [SubscriptionCandidate]) -> Double {
        items.reduce(0) { $0 + $1.estimatedMonthly }
    }

    // MARK: - User declarations

    /// Build candidates from transactions the user marked as weekly/monthly/yearly.
    nonisolated private static func collectDeclaredCandidates(
        from spend: [SubscriptionTxSnapshot],
        now: Date
    ) -> [SubscriptionCandidate] {
        let declared = spend.filter { $0.declaredSubscriptionCadence != nil }
        guard !declared.isEmpty else { return [] }

        var byKey: [String: [SubscriptionTxSnapshot]] = [:]
        for tx in declared {
            guard let cadence = tx.declaredSubscriptionCadence else { continue }
            let vendor = normalizeVendor(tx.title)
            guard vendor.count >= 2 else { continue }
            // Vendor + cadence only — phone and electric amounts change month to month.
            let key = "\(vendor)|\(cadence.rawValue)"
            byKey[key, default: []].append(tx)
        }

        var results: [SubscriptionCandidate] = []
        for (_, rows) in byKey {
            guard let cadence = rows.compactMap(\.declaredSubscriptionCadence).first else { continue }
            let vendor = normalizeVendor(rows[0].title)
            let related = spend.filter { tx in
                guard !tx.isDeclaredNotSubscription else { return false }
                guard normalizeVendor(tx.title) == vendor else { return false }
                if let other = tx.declaredSubscriptionCadence, other != cadence { return false }
                return true
            }
            let cluster = related.isEmpty ? rows : related
            let amounts = cluster.map { abs($0.amount) }
            let typical = median(amounts)
            let strongName = cluster.contains { looksLikeSubscriptionName($0.title) }
            results.append(
                makeCandidate(
                    key: vendor,
                    cluster: cluster.sorted { $0.date < $1.date },
                    typical: typical,
                    cadence: cadence,
                    strongName: strongName,
                    isUserDeclared: true,
                    now: now
                )
            )
        }
        return results
    }

    /// Build a candidate from a vendor cluster. Tight amount matching is for
    /// fixed-price subs; variable bills skip the spread check and use cadence.
    nonisolated private static func candidateFromCluster(
        key: String,
        cluster: [SubscriptionTxSnapshot],
        requireTightAmount: Bool,
        now: Date
    ) -> SubscriptionCandidate? {
        let declaredCadence = cluster.compactMap(\.declaredSubscriptionCadence).first
        let strongName = cluster.contains { looksLikeSubscriptionName($0.title) }
        let billLike = cluster.contains { looksLikeBillCategory($0.category) }
        let minCount = (strongName || billLike || declaredCadence != nil) ? 2 : 3
        guard cluster.count >= minCount || (declaredCadence != nil && cluster.count >= 1) else {
            return nil
        }
        if cluster.count < minCount, declaredCadence == nil { return nil }

        let amounts = cluster.map { abs($0.amount) }
        let typical = median(amounts)
        guard typical > 0 else { return nil }
        if requireTightAmount {
            guard amountSpreadOK(amounts, typical: typical) else { return nil }
        }

        let dates = cluster.map(\.date).sorted()
        let cadence: SubscriptionCadence
        if let declaredCadence {
            cadence = declaredCadence
        } else if let inferred = inferCadence(dates: dates, allowWeekly: strongName) {
            cadence = inferred
        } else {
            return nil
        }
        if cadence == .weekly, !strongName, declaredCadence == nil { return nil }

        return makeCandidate(
            key: key,
            cluster: cluster,
            typical: typical,
            cadence: cadence,
            strongName: strongName,
            isUserDeclared: declaredCadence != nil,
            now: now
        )
    }

    /// Shared builder for auto-detected and user-declared candidates.
    nonisolated private static func makeCandidate(
        key: String,
        cluster: [SubscriptionTxSnapshot],
        typical: Double,
        cadence: SubscriptionCadence,
        strongName: Bool,
        isUserDeclared: Bool,
        now: Date
    ) -> SubscriptionCandidate {
        let monthly: Double = {
            switch cadence {
            case .weekly: return typical * (52.0 / 12.0)
            case .monthly: return typical
            case .yearly: return typical / 12.0
            }
        }()
        let dates = cluster.map(\.date).sorted()
        let methods = Array(Set(cluster.map(\.cardName))).sorted()
        let display = cluster.max(by: { $0.date < $1.date })?.title ?? key
        let amounts = cluster.map { abs($0.amount) }
        let spread = (amounts.max() ?? typical) - (amounts.min() ?? typical)
        let amountVaries = spread > max(0.25, typical * 0.01)
        let note: String = {
            if isUserDeclared { return "Marked by you as \(cadence.displayName.lowercased())" }
            if amountVaries {
                if strongName { return "Name looks like a bill / membership; amount varies" }
                return "Regular \(cadence.displayName.lowercased()) schedule (amount varies)"
            }
            if strongName { return "Name looks like a membership / subscription" }
            return "Same amount on a regular \(cadence.displayName.lowercased()) schedule"
        }()
        return SubscriptionCandidate(
            displayVendor: prettyVendor(display),
            normalizedVendor: key,
            typicalAmount: typical,
            cadence: cadence,
            estimatedMonthly: monthly,
            occurrenceCount: cluster.count,
            lastDate: dates.last ?? now,
            paymentMethods: methods,
            sampleTransactionIds: cluster.map(\.transactionId),
            confidenceNote: note,
            isUserDeclared: isUserDeclared,
            amountVaries: amountVaries
        )
    }

    nonisolated private static func candidateKey(_ c: SubscriptionCandidate) -> String {
        "\(c.normalizedVendor)|\(String(format: "%.2f", c.typicalAmount))|\(c.cadence.rawValue)"
    }

    // MARK: - Exclude retail habits

    /// Categories that are usually “I shop here often,” not a fixed subscription bill.
    nonisolated private static func isHabitCategory(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let blocked = [
            "dining", "groceries", "grocery", "gas (car)", "gas", "transit",
            "shopping", "personal care", "health", "travel", "flights", "hotels",
            "housing", "pets", "fees",
            "transfer", "transfers", "credit card payment"
        ]
        return blocked.contains(c)
    }

    /// Spend categories that are usually a repeating bill, even when the amount changes.
    nonisolated private static func looksLikeBillCategory(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return c == "utilities" || c == "home internet" || c == "car insurance"
            || c == "subscriptions"
    }

    /// Title keywords for grocery/coffee/gas/etc. habits to exclude from auto-detect.
    nonisolated private static func looksLikeRetailHabit(title: String) -> Bool {
        let t = title.lowercased()
        let retail = [
            "walmart", "target", "costco", "sams club", "sam's club", "trader joe",
            "whole foods", "kroger", "safeway", "albertsons", "publix", "heb ", "h-e-b",
            "aldi", "lidl", "meijer", "food lion", "stop & shop", "wegmans",
            "sprouts", "market basket", "ralphs", "vons", "king soopers",
            "cvs", "walgreens", "rite aid", "duane reade",
            "starbucks", "dunkin", "dutch bros", "peets", "coffee",
            "mcdonald", "chipotle", "subway", "wendy", "taco bell", "burger king",
            "chick-fil", "chick fil", "panera", "domino", "pizza hut", "papa john",
            "five guys", "in-n-out", "innout", "shake shack", "sweetgreen", "cava ",
            "shell ", "chevron", "exxon", "mobil", "bp ", "circle k", "7-eleven",
            "7 eleven", "wawa", "sheetz", "quiktrip", "raceway", "speedway",
            "arco", "valero", "sunoco", "marathon",
            "uber trip", "uber eats", "lyft", "doordash", "grubhub", "instacart",
            "home depot", "lowe's", "lowes", "best buy", "ikea", "nordstrom",
            "macy", "tj maxx", "marshalls", "ross dress", "dollar tree", "dollar general",
            "amazon.com*amzn",
        ]
        if looksLikeSubscriptionName(title) { return false }
        return retail.contains { t.contains($0) }
    }

    /// Title keywords that strongly suggest a membership / streaming / SaaS charge.
    nonisolated private static func looksLikeSubscriptionName(_ title: String) -> Bool {
        let t = title.lowercased()
        let needles = [
            "subscription", "subscrip", "membership", "member fee", "premium",
            "recurring", "auto renew", "autorenew", "billing",
            "netflix", "hulu", "disney+", "disney plus", "disneyplus", "max.com", "hbo ",
            "spotify", "apple music", "apple.com/bill", "itunes.com", "icloud",
            "youtube premium", "youtube tv", "paramount+", "peacock", "crunchyroll",
            "audible", "kindle unlim", "prime video", "amazon prime", "amzn prime",
            "adobe", "microsoft*365", "microsoft 365", "office 365", "github",
            "dropbox", "1password", "lastpass", "notion", "slack", "zoom.us",
            "openai", "chatgpt", "anthropic", "cursor", "midjourney",
            "google*gsuite", "google workspace", "google one", "google storage",
            "planet fitness", "equinox", "peloton", "classpass",
            "hellofresh", "blue apron", "factor75", "factor meals",
            "comcast", "xfinity", "verizon", "vzw", "t-mobile", "tmobile",
            "at&t", "att* ", "spectrum", "google fi", "cricket wireless",
            "ynab", "mint ", "credit karma",
        ]
        return needles.contains { t.contains($0) }
    }

    // MARK: - Amount clustering

    /// Group transactions whose absolute amounts sit within a small tolerance of each other.
    nonisolated private static func exactAmountClusters(_ rows: [SubscriptionTxSnapshot]) -> [[SubscriptionTxSnapshot]] {
        var remaining = rows.sorted { abs($0.amount) < abs($1.amount) }
        var clusters: [[SubscriptionTxSnapshot]] = []

        while let seed = remaining.first {
            let seedAmt = abs(seed.amount)
            var cluster: [SubscriptionTxSnapshot] = []
            var rest: [SubscriptionTxSnapshot] = []
            let tol = max(0.25, seedAmt * 0.01)
            for tx in remaining {
                let a = abs(tx.amount)
                if abs(a - seedAmt) <= tol {
                    cluster.append(tx)
                } else {
                    rest.append(tx)
                }
            }
            clusters.append(cluster)
            remaining = rest
        }
        return clusters
    }

    /// True when every amount is close to the typical (median) value.
    nonisolated private static func amountSpreadOK(_ amounts: [Double], typical: Double) -> Bool {
        guard !amounts.isEmpty, typical > 0 else { return false }
        let maxDev = amounts.map { abs($0 - typical) }.max() ?? 0
        return maxDev <= max(0.25, typical * 0.01)
    }

    // MARK: - Cadence

    /// Infer weekly / monthly / yearly from gaps between charge dates.
    nonisolated private static func inferCadence(dates: [Date], allowWeekly: Bool) -> SubscriptionCadence? {
        guard dates.count >= 2 else { return nil }
        var gaps: [Double] = []
        for i in 1..<dates.count {
            let days = dates[i].timeIntervalSince(dates[i - 1]) / 86_400
            if days >= 5 { gaps.append(days) }
        }
        guard !gaps.isEmpty else { return nil }
        let med = median(gaps)

        let slack = max(3.0, med * 0.2)
        let near = gaps.filter { abs($0 - med) <= slack }
        let regularity = Double(near.count) / Double(gaps.count)
        guard regularity >= 0.66 else { return nil }

        if allowWeekly, med >= 6, med <= 9 { return .weekly }
        if med >= 27, med <= 35 { return .monthly }
        if med >= 350, med <= 400 { return .yearly }
        if dates.count == 2, med >= 27, med <= 35 { return .monthly }
        return nil
    }

    // MARK: - String helpers

    /// Collapse a noisy bank title into a short vendor key for grouping.
    nonisolated static func normalizeVendor(_ title: String) -> String {
        var s = title.lowercased()
        let junk = [
            #"\bpos\b"#, #"\bpurchase\b"#, #"\bdebit\b"#, #"\bcard\b"#,
            #"\bonline\b"#, #"\bweb\b"#,
            #"\b#\d+"#, #"\*\d+"#, #"\d{4,}"#
        ]
        for pattern in junk {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        s = s.split(separator: " ").joined(separator: " ")
        let tokens = s.split(separator: " ").prefix(3)
        return tokens.joined(separator: " ")
    }

    nonisolated private static func prettyVendor(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 40 { return t }
        return String(t.prefix(37)) + "…"
    }

    nonisolated private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        if s.count % 2 == 0 {
            return (s[mid - 1] + s[mid]) / 2
        }
        return s[mid]
    }
}
