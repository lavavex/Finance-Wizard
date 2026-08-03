//
//  PeriodFilterMenu.swift
//  Finance Wizard
//
//  Calendar toolbar control: week / month / all, plus a list of months
//  when “Month” is selected so you can jump to past Apple Card months.
//  Teaches: View, @Binding, Menu, Picker, ForEach, custom Binding.
//

import SwiftUI

/// Toolbar menu for choosing SnapshotPeriod (week / month / all) and optionally which month.
///
/// View is a SwiftUI protocol: anything with a `body` that returns UI can go on screen.
/// This struct is not a full screen — it is a small control you put in a toolbar.
struct PeriodFilterMenu: View {
    // @Binding means this property is shared with a parent view.
    // When the user picks a new period, the parent’s @State updates too (two-way link).
    // The $ prefix (used below) creates a Binding from @State or passes one along.
    @Binding var period: SnapshotPeriod
    /// Any date inside the week/month to show (normalized to month start when picking a month).
    @Binding var referenceDate: Date
    /// Used to build the list of months that have transactions.
    // `let` here is a one-way input from the parent (read-only; not a Binding).
    let transactions: [Transaction]
    /// Extra dates (e.g. credit payments) so month picker isn’t empty on other tabs.
    // Default parameter (= []) means callers can omit this argument.
    var additionalDates: [Date] = []
    /// Icon-only (transactions tab) vs labeled (cards / categories).
    var showTitle: Bool = true

    // Computed property: recalculated whenever body is re-evaluated.
    // Key-path syntax `\.date` means “the date property of each transaction.”
    private var monthStarts: [Date] {
        TransactionAnalytics.availableMonthStarts(
            from: transactions.map(\.date) + additionalDates
        )
    }

    private var labelText: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    // body is required by View. SwiftUI calls it to build (and rebuild) the UI
    // when @Binding values or other inputs change.
    var body: some View {
        // Menu shows a popup of actions when tapped (common in toolbars).
        Menu {
            // Week / Month / All time
            // Picker presents choices; selection: uses a Binding so the choice is stored.
            // periodSelection is a custom Binding that also resets referenceDate (see below).
            Picker("Period", selection: periodSelection) {
                // ForEach loops over a collection and builds a view for each item.
                // SnapshotPeriod.allCases comes from CaseIterable on an enum.
                ForEach(SnapshotPeriod.allCases) { option in
                    // .tag tells the Picker which value this row represents when selected.
                    Text(option.displayName).tag(option)
                }
            }

            // Only when viewing by month: pick which calendar month
            // if inside body is fine — SwiftUI only builds the Section when the condition is true.
            if period == .month {
                Divider() // thin line between menu groups
                Section("Month") {
                    // id: \.self means each Date is its own identity (Dates are Hashable).
                    ForEach(monthStarts, id: \.self) { monthStart in
                        // Button runs a closure when tapped. Here we write into the @Binding.
                        Button {
                            referenceDate = monthStart
                        } label: {
                            // HStack lays views out horizontally (left to right).
                            HStack {
                                Text(Self.monthPickerLabel(for: monthStart))
                                // Checkmark for the currently selected month.
                                if Calendar.current.isDate(monthStart, equalTo: referenceDate, toGranularity: .month) {
                                    Image(systemName: "checkmark") // SF Symbol name
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            // label: is what the user sees before opening the menu.
            if showTitle {
                // Label pairs text with an SF Symbol icon.
                Label(labelText, systemImage: "calendar")
            } else {
                Image(systemName: "calendar")
            }
        }
        // Accessibility modifiers help VoiceOver describe the control.
        .accessibilityLabel("Period")
        .accessibilityValue(labelText)
    }

    /// Changing the period resets the reference to “now” so Month → This month, Week → this week.
    ///
    /// Custom Binding: get reads the real property; set runs extra logic when the Picker changes.
    /// Useful when selection should update more than one piece of state.
    private var periodSelection: Binding<SnapshotPeriod> {
        Binding(
            get: { period },
            set: { newPeriod in
                period = newPeriod
                // switch matches an enum value and runs the matching case.
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
    /// static means you call it on the type (Self.monthPickerLabel) without an instance.
    /// Default argument `now: Date = Date()` is useful for tests that pass a fixed date.
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
