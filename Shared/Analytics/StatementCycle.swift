//
//  StatementCycle.swift
//  Finance Wizard
//
//  Group card activity by statement close (from Plaid last_statement_issue_date).
//  Fallback: calendar months when the bank has not sent a close date.
//

import Foundation

/// One statement window: day after the previous close through this close (inclusive).
struct StatementBucket: Identifiable {
    let start: Date
    let end: Date
    /// True when this window has not closed yet.
    let isOpen: Bool

    var id: TimeInterval { end.timeIntervalSince1970 }

    var title: String {
        if isOpen { return "Current statement" }
        return "Statement closed \(end.formatted(date: .abbreviated, time: .omitted))"
    }

    var rangeLabel: String {
        let a = start.formatted(date: .abbreviated, time: .omitted)
        let b = end.formatted(date: .abbreviated, time: .omitted)
        return "\(a) – \(b)"
    }
}

enum StatementCycle {
    /// Day-of-month the statement closes, from the last issued statement.
    static func closeDay(from lastStatement: Date?, calendar: Calendar = .current) -> Int? {
        guard let last = lastStatement else { return nil }
        return calendar.component(.day, from: calendar.startOfDay(for: last))
    }

    /// Statement close that includes `date` for a close-on-this-day cycle.
    static func statementEnd(
        containing date: Date,
        closeDay: Int,
        calendar: Calendar = .current
    ) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let day = calendar.component(.day, from: dayStart)
        var comps = calendar.dateComponents([.year, .month], from: dayStart)
        if day <= closeDay {
            comps.day = closeDay
            return clampedDate(comps, calendar: calendar)
        }
        guard let monthStart = calendar.date(from: comps),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return dayStart
        }
        var next = calendar.dateComponents([.year, .month], from: nextMonth)
        next.day = closeDay
        return clampedDate(next, calendar: calendar)
    }

    /// FIX: subtracting a month from the close date is not the same as the previous close.
    /// With a 31st close day, the window ending Feb 28 started "Jan 29" — three days that
    /// actually belong to the January statement — so the header range disagreed with the
    /// rows in it. Derive the previous close from `closeDay` and clamp it the same way.
    /// OLD:
    /// guard let prevEnd = calendar.date(byAdding: .month, value: -1, to: endDay) else { … }
    /// return calendar.date(byAdding: .day, value: 1, to: prevEnd) ?? endDay
    static func statementStart(end: Date, closeDay: Int? = nil, calendar: Calendar = .current) -> Date {
        let endDay = calendar.startOfDay(for: end)
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: endDay) else {
            return endDay
        }
        let previousEnd: Date
        if let closeDay {
            var comps = calendar.dateComponents([.year, .month], from: previousMonth)
            comps.day = closeDay
            previousEnd = clampedDate(comps, calendar: calendar)
        } else {
            previousEnd = previousMonth
        }
        return calendar.date(byAdding: .day, value: 1, to: previousEnd) ?? endDay
    }

    /// Newest-first buckets covering every transaction. `closeDay` nil → calendar months.
    /// `lastStatement` is the issuer's last statement date: anything ending on or before it
    /// has genuinely closed, which is more reliable than comparing the end against today.
    static func group(
        _ transactions: [Transaction],
        closeDay: Int?,
        lastStatement: Date? = nil,
        now: Date = Date(),
        sort: TransactionSort = .dateNewest
    ) -> [(bucket: StatementBucket, rows: [Transaction])] {
        guard !transactions.isEmpty else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let issued = lastStatement.map { calendar.startOfDay(for: $0) }
        var grouped: [Date: [Transaction]] = [:]
        for tx in transactions {
            let end: Date
            if let closeDay {
                end = statementEnd(containing: tx.date, closeDay: closeDay, calendar: calendar)
            } else {
                end = monthEnd(containing: tx.date, calendar: calendar)
            }
            grouped[end, default: []].append(tx)
        }
        return grouped.keys.sorted(by: >).map { end in
            let start: Date
            if let closeDay {
                start = statementStart(end: end, closeDay: closeDay, calendar: calendar)
            } else {
                start = monthStart(containing: end, calendar: calendar)
            }
            // FIX: "end >= today" called a cycle that closed today still open, and had no
            // way to know whether the issuer had actually issued the statement. When we
            // know the last statement date, a bucket is open only if it ends after it.
            // OLD: isOpen: calendar.startOfDay(for: end) >= today
            let endDay = calendar.startOfDay(for: end)
            let bucket = StatementBucket(
                start: start,
                end: end,
                isOpen: issued.map { endDay > $0 } ?? (endDay >= today)
            )
            let rows = TransactionAnalytics.sorted(grouped[end] ?? [], by: sort)
            return (bucket, rows)
        }
    }

    /// FIX: the old version asked Calendar for the literal date first and only clamped when
    /// that returned nil — but Calendar.date(from:) is lenient and never fails here. It
    /// rolls over instead: 2026-02-31 becomes 2026-03-03. So a card closing on the 29th,
    /// 30th or 31st produced February buckets stamped in March, labelled with a range that
    /// did not contain their own rows. Clamp the day to the month's length up front.
    /// OLD:
    /// if let exact = calendar.date(from: comps) { return calendar.startOfDay(for: exact) }
    /// … then fall back to the last day of the month …
    /// The cycle card screens should summarise: the open one, or the most recent closed
    /// cycle when nothing has posted since the last close.
    /// FIX: AccountsBoard used the open cycle only (showing $0) while CardDetailView fell
    /// back to the newest closed cycle and still labelled it "This statement". The list and
    /// the detail screen disagreed for any card with no activity since its close date.
    /// Both call this now, and both read `bucket.isOpen` for the label.
    static func currentGroup(
        in groups: [(bucket: StatementBucket, rows: [Transaction])]
    ) -> (bucket: StatementBucket, rows: [Transaction])? {
        groups.first(where: { $0.bucket.isOpen }) ?? groups.first
    }

    private static func clampedDate(_ comps: DateComponents, calendar: Calendar) -> Date {
        var month = DateComponents()
        month.year = comps.year
        month.month = comps.month
        month.day = 1
        guard let start = calendar.date(from: month),
              let range = calendar.range(of: .day, in: .month, for: start) else {
            return calendar.startOfDay(for: Date())
        }
        var clamped = month
        // A close day past the end of a short month lands on that month's last day.
        clamped.day = min(max(comps.day ?? 1, 1), range.count)
        return calendar.startOfDay(for: calendar.date(from: clamped) ?? start)
    }

    private static func monthStart(containing date: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: c).map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
    }

    private static func monthEnd(containing date: Date, calendar: Calendar) -> Date {
        let start = monthStart(containing: date, calendar: calendar)
        guard let next = calendar.date(byAdding: .month, value: 1, to: start),
              let last = calendar.date(byAdding: .day, value: -1, to: next) else {
            return start
        }
        return calendar.startOfDay(for: last)
    }
}
