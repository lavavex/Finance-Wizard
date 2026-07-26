//
//  AppSettings.swift
//  FinanceWidget
//
//  User preferences (server URL, etc.) persisted with AppStorage / UserDefaults.
//

import Foundation
import SwiftUI

// Keys and defaults for settings the user can change
enum AppSettings {
    // UserDefaults key for the finance-sync base URL (no trailing path)
    static let serverBaseURLKey = "serverBaseURL"

    // Default portal address (LAN hostname)
    static let defaultServerBaseURL = "http://openwindow.local:8787"

    // Read the configured base URL (used outside Views, e.g. sync helpers)
    static var serverBaseURL: String {
        let stored = UserDefaults.standard.string(forKey: serverBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty {
            return defaultServerBaseURL
        }
        // Strip trailing slash so we can append "/api/..."
        if stored.hasSuffix("/") {
            return String(stored.dropLast())
        }
        return stored
    }

    // YYYY-MM strings for “this month” and “previous month” (calendar-local)
    static func currentAndPreviousMonths(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let formatter = DateFormatter()
        // Stable month formatting regardless of device language
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"

        let current = formatter.string(from: now)
        // Go back one calendar month from “now”
        guard let previousDate = calendar.date(byAdding: .month, value: -1, to: now) else {
            return [current]
        }
        let previous = formatter.string(from: previousDate)

        // Prefer current first; drop duplicate if any odd calendar edge case
        if current == previous {
            return [current]
        }
        return [current, previous]
    }

    // Friendly label for Settings, e.g. "2026-07, 2026-06"
    static func syncMonthsDescription(now: Date = Date()) -> String {
        currentAndPreviousMonths(now: now).joined(separator: ", ")
    }
}
