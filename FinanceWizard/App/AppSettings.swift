//
//  AppSettings.swift
//  Finance Wizard
//
//  Small helpers for app preferences and labels (e.g. which months a sync covers).
//  Plaid credentials live elsewhere: PlaidCredentialsStore (Keychain + UserDefaults).
//

import Foundation
import SwiftUI

enum AppSettings {
    /// YYYY-MM strings for this month and the previous month (calendar-local).
    static func currentAndPreviousMonths(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let formatter = DateFormatter()
        // en_US_POSIX so yyyy-MM is stable regardless of the user’s language.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"

        let current = formatter.string(from: now)
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
    static func syncMonthsDescription(now: Date = Date()) -> String {
        currentAndPreviousMonths(now: now).joined(separator: ", ")
    }
}
