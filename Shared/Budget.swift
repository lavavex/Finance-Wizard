//
//  Budget.swift
//  Finance Wizard
//
//  Monthly budgeting: overall cap + per-category limits.
//

import Foundation
import SwiftData

/// Singleton-style plan (one row). Category caps live in `categoryLimitsJSON`.
@Model
final class BudgetPlan {
    /// Stable key so we always load the same plan.
    @Attribute(.unique) var planId: String

    /// Optional overall monthly spend target (USD). Nil / 0 = no overall cap.
    var monthlyLimit: Double?

    /// JSON dictionary: category name → limit (USD).
    var categoryLimitsJSON: Data?

    var updatedAt: Date

    init(
        planId: String = "default",
        monthlyLimit: Double? = nil,
        categoryLimits: [String: Double] = [:],
        updatedAt: Date = Date()
    ) {
        self.planId = planId
        self.monthlyLimit = monthlyLimit
        self.categoryLimitsJSON = Self.encodeLimits(categoryLimits)
        self.updatedAt = updatedAt
    }

    var categoryLimits: [String: Double] {
        get { Self.decodeLimits(categoryLimitsJSON) }
        set {
            categoryLimitsJSON = Self.encodeLimits(newValue)
            updatedAt = Date()
        }
    }

    func limit(forCategory category: String) -> Double? {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = categoryLimits[key], v > 0 { return v }
        // Case-insensitive match
        if let hit = categoryLimits.first(where: {
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }), hit.value > 0 {
            return hit.value
        }
        return nil
    }

    func setLimit(_ amount: Double?, forCategory category: String) {
        var map = categoryLimits
        let key = KnownCategory.canonicalName(for: category) ?? category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let amount, amount > 0 {
            map[key] = amount
        } else {
            map.removeValue(forKey: key)
            // Also drop any case variants
            map = map.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
        }
        categoryLimits = map
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
}

// MARK: - Store helpers

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
