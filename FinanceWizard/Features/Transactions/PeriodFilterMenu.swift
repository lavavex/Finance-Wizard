//
//  PeriodFilterMenu.swift
//  Finance Wizard
//
//  Calendar toolbar control: week / month / all, plus a list of months
//  when “Month” is selected so you can jump to past months.
//

import SwiftUI

/// Toolbar menu for choosing SnapshotPeriod (week / month / all) and optionally which month.
struct PeriodFilterMenu: View {
    @Binding var period: SnapshotPeriod
    /// Any date inside the week/month to show (normalized to month start when picking a month).
    @Binding var referenceDate: Date
    /// Used to build the list of months that have transactions.
    let transactions: [Transaction]
    /// Extra dates (e.g. credit payments) so month picker isn’t empty on other tabs.
    var additionalDates: [Date] = []
    /// Icon-only (transactions tab) vs labeled (cards / categories).
    var showTitle: Bool = true

    private var monthStarts: [Date] {
        TransactionAnalytics.availableMonthStarts(
            from: transactions.map(\.date) + additionalDates
        )
    }

    private var labelText: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    var body: some View {
        Menu {
            Picker("Period", selection: periodSelection) {
                ForEach(SnapshotPeriod.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            if period == .month {
                Divider()
                Section("Month") {
                    ForEach(monthStarts, id: \.self) { monthStart in
                        Button {
                            referenceDate = monthStart
                        } label: {
                            HStack {
                                Text(Self.monthPickerLabel(for: monthStart))
                                if Calendar.current.isDate(monthStart, equalTo: referenceDate, toGranularity: .month) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            if showTitle {
                Label(labelText, systemImage: "calendar")
            } else {
                Image(systemName: "calendar")
            }
        }
        .accessibilityLabel("Period")
        .accessibilityValue(labelText)
    }

    /// Changing the period resets the reference to “now” so Month → This month, Week → this week.
    private var periodSelection: Binding<SnapshotPeriod> {
        Binding(
            get: { period },
            set: { newPeriod in
                period = newPeriod
                switch newPeriod {
                case .month:
                    referenceDate = TransactionAnalytics.monthStart(for: Date())
                case .week:
                    referenceDate = Date()
                case .all:
                    break // no referenceDate change needed for “all time”
                }
            }
        )
    }

    /// “July 2026” or “This month” for the current calendar month.
    private static func monthPickerLabel(for monthStart: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(monthStart, equalTo: now, toGranularity: .month) {
            return "This month"
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        // Template adapts month/year order to the user’s locale.
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: monthStart)
    }
}
