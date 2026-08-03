//
//  AppSettings.swift
//  Finance Wizard
//
//  Small helpers for app preferences and labels (e.g. which months a sync covers).
//  Plaid credentials live elsewhere: PlaidCredentialsStore (Keychain + UserDefaults).
//

// Foundation: core types like Date, Calendar, DateFormatter (not UI).
import Foundation
// SwiftUI import keeps this file available to UI code that may call these helpers.
import SwiftUI

// enum with only static methods is a common Swift pattern for a “namespace”
// (no instances of AppSettings are created; you call AppSettings.currentAndPreviousMonths()).
enum AppSettings {
    // static means the function belongs to the type itself, not to an instance.
    // Default parameter values (now:, calendar:) let callers omit them.
    // Returns YYYY-MM strings for “this month” and “previous month” (calendar-local).
    static func currentAndPreviousMonths(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        // DateFormatter converts Date ↔ String using a format pattern.
        let formatter = DateFormatter()
        // en_US_POSIX is a fixed locale so yyyy-MM always means the same thing
        // regardless of the user’s language settings.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"

        let current = formatter.string(from: now)
        // guard let: if the optional is nil, exit early with return (or throw, etc.).
        // calendar.date(byAdding:) returns Date? because date math can fail in edge cases.
        guard let previousDate = calendar.date(byAdding: .month, value: -1, to: now) else {
            return [current]
        }
        let previous = formatter.string(from: previousDate)

        // Same label twice (rare calendar edge) → only one entry.
        if current == previous {
            return [current]
        }
        return [current, previous]
    }

    /// Friendly label for Settings UI, e.g. "2026-07, 2026-06".
    /// /// is documentation-style comment (shows in Quick Help / autocomplete).
    static func syncMonthsDescription(now: Date = Date()) -> String {
        // joined(separator:) turns ["2026-07", "2026-06"] into "2026-07, 2026-06".
        currentAndPreviousMonths(now: now).joined(separator: ", ")
    }
}
