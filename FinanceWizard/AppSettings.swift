//
//  AppSettings.swift
//  Finance Wizard
//
//  App preferences helpers (sync window labels, etc.).
//  Plaid credentials live in PlaidCredentialsStore (Keychain + UserDefaults).
//

import Foundation
import SwiftUI

enum AppSettings {
    // YYYY-MM strings for “this month” and “previous month” (calendar-local)
    static func currentAndPreviousMonths(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"

        let current = formatter.string(from: now)
        guard let previousDate = calendar.date(byAdding: .month, value: -1, to: now) else {
            return [current]
        }
        let previous = formatter.string(from: previousDate)

        if current == previous {
            return [current]
        }
        return [current, previous]
    }

    /// Friendly label for Settings, e.g. "2026-07, 2026-06"
    static func syncMonthsDescription(now: Date = Date()) -> String {
        currentAndPreviousMonths(now: now).joined(separator: ", ")
    }
}
