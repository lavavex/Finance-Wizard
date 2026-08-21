//
//  Budget.swift
//  Finance Wizard
//
//  Monthly budgeting: overall cap, per-category limits, expected income streams.
//

import Foundation
import SwiftData

// MARK: - Expected income

/// How often a planned income hits.
enum ExpectedIncomeFrequency: String, CaseIterable, Identifiable, Codable, Sendable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// Rough occurrences per calendar month (for burn / headroom estimates).
    var occurrencesPerMonth: Double {
        switch self {
        case .daily: return 365.0 / 12.0
        case .weekly: return 52.0 / 12.0
        case .monthly: return 1
        }
    }
}

/// One planned income source (paycheck, side hustle, etc.). Stored as JSON on BudgetPlan.
struct ExpectedIncomeStream: Identifiable, Codable, Hashable, Sendable {
    var id: String
    /// User label, e.g. "Payroll", "Venmo clients".
    var label: String
    /// Amount per occurrence (not necessarily monthly).
    var amount: Double
    var frequency: ExpectedIncomeFrequency
    /// Weekly: `Calendar` weekday 1…7 (1 = Sunday in Gregorian US).
    var weekday: Int?
    /// Monthly: day of month 1…31 (clamped to month length when scheduling).
    var dayOfMonth: Int?

    init(
        id: String = UUID().uuidString,
        label: String = "Income",
        amount: Double,
        frequency: ExpectedIncomeFrequency = .monthly,
        weekday: Int? = nil,
        dayOfMonth: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.amount = amount
        self.frequency = frequency
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
    }

    /// Estimated monthly total from this stream.
    var estimatedMonthly: Double {
        max(0, amount) * frequency.occurrencesPerMonth
    }

    /// Human schedule, e.g. "Monthly on the 1st", "Weekly on Friday".
    var scheduleDescription: String {
        switch frequency {
        case .daily:
            return "Every day"
        case .weekly:
            if let weekday, let name = Self.weekdayName(weekday) {
                return "Weekly on \(name)"
            }
            return "Weekly"
        case .monthly:
            if let day = dayOfMonth {
                return "Monthly on the \(Self.ordinal(day))"
            }
            return "Monthly"
        }
    }

    /// Next expected pay date on or after `from` (calendar local).
    func nextDate(from: Date = Date(), calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: from)
        switch frequency {
        case .daily:
            return start
        case .weekly:
            guard let weekday else { return nil }
            let current = calendar.component(.weekday, from: start)
            var delta = weekday - current
            if delta < 0 { delta += 7 }
            return calendar.date(byAdding: .day, value: delta, to: start)
        case .monthly:
            guard let targetDay = dayOfMonth, targetDay >= 1 else { return nil }
            let comps = calendar.dateComponents([.year, .month], from: start)
            guard let year = comps.year, let month = comps.month else { return nil }

            func dateIn(year: Int, month: Int) -> Date? {
                guard let range = calendar.range(of: .day, in: .month, for:
                    calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? start
                ) else { return nil }
                let day = min(targetDay, range.count)
                return calendar.date(from: DateComponents(year: year, month: month, day: day))
            }

            if let thisMonth = dateIn(year: year, month: month), thisMonth >= start {
                return thisMonth
            }
            var nextMonth = month + 1
            var nextYear = year
            if nextMonth > 12 {
                nextMonth = 1
                nextYear += 1
            }
            return dateIn(year: nextYear, month: nextMonth)
        }
    }

    /// Expected dollars landing inside a period window (for vs actual).
    /// Walks pay dates with a safety cap so a bug cannot infinite-loop.
    func expectedAmount(
        in period: SnapshotPeriod,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Double {
        let range = TransactionAnalytics.dateInterval(
            for: period,
            referenceDate: referenceDate,
            calendar: calendar
        )
        guard let range else {
            return estimatedMonthly
        }
        let start = calendar.startOfDay(for: range.start)
        let endExclusive = range.end
        var total = 0.0
        var cursor = start
        var safety = 0
        while cursor < endExclusive, safety < 400 {
            safety += 1
            guard let next = nextDate(from: cursor, calendar: calendar) else { break }
            if next >= endExclusive { break }
            if next >= start {
                total += max(0, amount)
            }
            guard let advanced = calendar.date(byAdding: .day, value: 1, to: next) else { break }
            cursor = advanced
        }
        return total
    }

    private static func weekdayName(_ weekday: Int) -> String? {
        let symbols = Calendar.current.weekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return nil }
        return symbols[weekday - 1]
    }

    private static func ordinal(_ n: Int) -> String {
        let abs = abs(n)
        let mod100 = abs % 100
        if (11...13).contains(mod100) { return "\(n)th" }
        switch abs % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

// MARK: - Plan model

/// Singleton-style plan (one row). Category caps + expected income in JSON blobs.
/// SwiftData stores simple types easily; dictionaries and custom structs are encoded as Data.
@Model
final class BudgetPlan {
    /// Stable key so we always load the same plan.
    @Attribute(.unique) var planId: String

    /// Optional overall monthly spend target (USD). Nil / 0 = no overall cap.
    var monthlyLimit: Double?

    /// JSON dictionary: category name → limit (USD). Stored as Data?, decoded on read.
    var categoryLimitsJSON: Data?

    /// JSON array of `ExpectedIncomeStream` for smart / dynamic budgets.
    var expectedIncomeJSON: Data?

    var updatedAt: Date

    init(
        planId: String = "default",
        monthlyLimit: Double? = nil,
        categoryLimits: [String: Double] = [:],
        expectedIncome: [ExpectedIncomeStream] = [],
        updatedAt: Date = Date()
    ) {
        self.planId = planId
        self.monthlyLimit = monthlyLimit
        self.categoryLimitsJSON = Self.encodeLimits(categoryLimits)
        self.expectedIncomeJSON = Self.encodeExpectedIncome(expectedIncome)
        self.updatedAt = updatedAt
    }

    var categoryLimits: [String: Double] {
        get { Self.decodeLimits(categoryLimitsJSON) }
        set {
            categoryLimitsJSON = Self.encodeLimits(newValue)
            updatedAt = Date()
        }
    }

    var expectedIncomeStreams: [ExpectedIncomeStream] {
        get { Self.decodeExpectedIncome(expectedIncomeJSON) }
        set {
            expectedIncomeJSON = Self.encodeExpectedIncome(newValue)
            updatedAt = Date()
        }
    }

    /// Sum of estimated monthly income across all streams.
    var expectedMonthlyIncome: Double {
        expectedIncomeStreams.reduce(0) { $0 + $1.estimatedMonthly }
    }

    /// Look up a category cap; tries exact key then case-insensitive match.
    func limit(forCategory category: String) -> Double? {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = categoryLimits[key], v > 0 { return v }
        if let hit = categoryLimits.first(where: {
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }), hit.value > 0 {
            return hit.value
        }
        return nil
    }

    /// Set or clear a category limit (amount nil/≤0 removes the key).
    func setLimit(_ amount: Double?, forCategory category: String) {
        var map = categoryLimits
        let key = KnownCategory.canonicalName(for: category) ?? category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let amount, amount > 0 {
            map[key] = amount
        } else {
            map.removeValue(forKey: key)
            map = map.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
        }
        categoryLimits = map
    }

    func upsertExpectedIncome(_ stream: ExpectedIncomeStream) {
        var list = expectedIncomeStreams
        if let idx = list.firstIndex(where: { $0.id == stream.id }) {
            list[idx] = stream
        } else {
            list.append(stream)
        }
        expectedIncomeStreams = list
    }

    func removeExpectedIncome(id: String) {
        expectedIncomeStreams = expectedIncomeStreams.filter { $0.id != id }
    }

    private static func encodeLimits(_ map: [String: Double]) -> Data? {
        try? JSONEncoder().encode(map)
    }

    private static func decodeLimits(_ data: Data?) -> [String: Double] {
        guard let data,
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func encodeExpectedIncome(_ streams: [ExpectedIncomeStream]) -> Data? {
        try? JSONEncoder().encode(streams)
    }

    private static func decodeExpectedIncome(_ data: Data?) -> [ExpectedIncomeStream] {
        guard let data,
              let list = try? JSONDecoder().decode([ExpectedIncomeStream].self, from: data) else {
            return []
        }
        return list
    }
}

// MARK: - Store helpers

/// Load the single default plan, or create it if the store is empty.
enum BudgetStore {
    static let defaultPlanId = "default"

    @MainActor
    static func loadOrCreate(in modelContext: ModelContext) -> BudgetPlan {
        let id = defaultPlanId
        var descriptor = FetchDescriptor<BudgetPlan>(
            predicate: #Predicate<BudgetPlan> { $0.planId == id }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let plan = BudgetPlan(planId: id)
        modelContext.insert(plan)
        try? modelContext.save()
        return plan
    }
}
