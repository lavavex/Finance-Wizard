//
//  ContentView.swift
//  FinanceWidget
//
//  Root tabs: All transactions (with filters) + By Card.
//

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import WidgetKit

// MARK: - API / file decode shapes

struct ImportedTransaction: Decodable {
    let transaction_id: String
    let date: String
    let vendor: String
    let category: String
    let amount: Double
    let payment_method: String
    let multiplier: Double
    // Present after classify / lock on finance-sync (optional for older exports)
    let category_locked: Bool?
    let multiplier_locked: Bool?
    let override_source: String?
}

struct ExportFile: Decodable {
    let transactions: [ImportedTransaction]
}

// Income stream from GET /api/income — shape matches finance-sync IncomeApiResponse / IncomeRow
struct ImportedIncome: Decodable {
    let transaction_id: String
    let date: String
    let month_name: String?
    let year: Int?
    /// Employer / payer / short label (display name)
    let source: String
    let category: String
    /// Always > 0 (money in)
    let amount: Double
    let account_name: String?
    let account_mask: String?
    let source_institution: String?
    let raw_name: String?
    let pfc: String?
    let pending: Bool?
    let kind: String?
    let updated_at: String?
}

struct IncomeExportFile: Decodable {
    let ok: Bool?
    let kind: String?
    let count: Int?
    /// Server sum of amounts in this response (prefer for month-filtered pull)
    let total: Double?
    let categories: [String]?
    // Optional so empty payloads without the key still decode
    let income: [ImportedIncome]?

    var rows: [ImportedIncome] { income ?? [] }
}

// MARK: - Root: three tabs

struct ContentView: View {
    var body: some View {
        TabView {
            // Tab 1: full list with the same period / sort / hide-card filters as the widget
            AllTransactionsView()
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet")
                }

            // Tab 2: browse by payment method / card
            CardsView()
                .tabItem {
                    Label("By Card", systemImage: "creditcard")
                }

            // Tab 3: server URL and sync info
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

// MARK: - All transactions tab

struct AllTransactionsView: View {
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Environment(\.modelContext) private var modelContext

    @State private var isImporting = false
    @State private var importError: String?
    @State private var isSyncing = false

    // Live + final Sync Status panel (Plaid result, month downloads, etc.)
    @State private var syncStatusTitle: String = ""
    @State private var syncStatusDetail: String = ""
    @State private var syncStatusKind: SyncStatusKind = .idle
    /// Keeps the status section visible after a run until the next Sync
    @State private var showSyncStatus = false

    // Same filter concepts as the widget
    @State private var period: SnapshotPeriod = .month
    /// Which week/month to show (any day in that period; months use month start).
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    // Cards hidden from the list (does not change Total Spend header)
    @State private var hiddenCards: Set<String> = []

    // Rows for the list: period + hide cards + sort
    private var visibleTransactions: [Transaction] {
        TransactionAnalytics.filter(
            transactions,
            period: period,
            referenceDate: referenceDate,
            excludedCards: hiddenCards,
            sort: sort
        )
    }

    // Period-only set (for totals — hide cards does not apply)
    private var periodTransactions: [Transaction] {
        TransactionAnalytics.inPeriod(transactions, period: period, referenceDate: referenceDate)
    }

    // Income for the same period filter (never mixed into spend)
    private var periodIncome: [Income] {
        IncomeAnalytics.inPeriod(incomeRows, period: period, referenceDate: referenceDate)
    }

    private var visibleIncome: [Income] {
        IncomeAnalytics.filter(
            incomeRows,
            period: period,
            referenceDate: referenceDate,
            sort: sort
        )
    }

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    // Big number: all cards in the period (expenses only)
    private var totalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
    }

    // Money earned in the period (GET /api/income; always positive)
    private var totalIncome: Double {
        IncomeAnalytics.totalEarned(in: periodIncome)
    }

    // Optional net: earned − spent for the same period (instruct “net” example)
    private var periodNet: Double {
        totalIncome - totalSpend
    }

    // Cards available to hide (from full store, so you can hide even if not in period)
    private var allCards: [String] {
        TransactionAnalytics.paymentMethods(in: transactions)
    }

    var body: some View {
        NavigationStack {
            List {
                // Live / last Sync Status (Plaid + downloads)
                if showSyncStatus || isSyncing {
                    Section("Sync Status") {
                        HStack(alignment: .top, spacing: 12) {
                            if isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: syncStatusKind.systemImage)
                                    .foregroundStyle(syncStatusKind.color)
                                    .font(.title3)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(syncStatusTitle.isEmpty ? "Working…" : syncStatusTitle)
                                    .font(.subheadline.weight(.semibold))
                                if !syncStatusDetail.isEmpty {
                                    Text(syncStatusDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Totals — spend from expenses only; income is a separate stream
                Section {
                    NavigationLink {
                        CategorySpendView(period: period, referenceDate: referenceDate)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Spend")
                                    .font(.headline)
                                Text(periodLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Tap for category chart")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(totalSpend, format: .currency(code: "USD"))
                                .font(.title2.bold())
                                .foregroundStyle(.primary)
                        }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Income")
                                .font(.headline)
                            Text(periodLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(totalIncome, format: .currency(code: "USD"))
                            .font(.title2.bold())
                            .foregroundStyle(.green)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Net")
                                .font(.subheadline.weight(.semibold))
                            Text("Income − spend")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(periodNet, format: .currency(code: "USD"))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(periodNet >= 0 ? .green : .primary)
                    }
                    Text("\(periodTransactions.count) expenses · \(periodIncome.count) income in \(periodLabel.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !hiddenCards.isEmpty {
                        Text("Hiding \(hiddenCards.count) card(s) from the expense list only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Income") {
                    if visibleIncome.isEmpty {
                        Text(incomeEmptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleIncome) { row in
                            NavigationLink {
                                IncomeDetailView(income: row)
                            } label: {
                                IncomeRowView(income: row)
                            }
                        }
                    }
                }

                Section("Expenses") {
                    if visibleTransactions.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleTransactions) { transaction in
                            // Tap row → full detail + edit category / multiplier
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                TransactionRowView(transaction: transaction)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Finances")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSyncing {
                        ProgressView()
                    } else {
                        // Quick sync (2 months) + full history pull
                        Menu {
                            Button {
                                Task { await syncFromServer(scope: .recent) }
                            } label: {
                                Label("Sync recent months", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                Task { await syncFromServer(scope: .everything) }
                            } label: {
                                Label("Sync everything", systemImage: "arrow.down.circle")
                            }
                        } label: {
                            Text("Sync")
                        }
                        .disabled(isSyncing)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Period + which month (when Month is selected)
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        showTitle: false
                    )

                    // Sort
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TransactionSort.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    // Hide cards from list only
                    Menu {
                        if allCards.isEmpty {
                            Text("No cards yet — Sync first")
                        } else {
                            ForEach(allCards, id: \.self) { card in
                                Button {
                                    toggleHidden(card)
                                } label: {
                                    HStack {
                                        Text(card)
                                        if hiddenCards.contains(card) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            if !hiddenCards.isEmpty {
                                Divider()
                                Button("Show all cards", role: .destructive) {
                                    hiddenCards.removeAll()
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "eye.slash")
                    }

                    Button("Import") {
                        isImporting = true
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var emptyMessage: String {
        if transactions.isEmpty {
            return "No expenses yet. Tap Sync or Import."
        }
        if periodTransactions.isEmpty {
            return "No expenses in \(periodLabel.lowercased())."
        }
        return "All cards in this period are hidden. Show some cards to see the list."
    }

    private var incomeEmptyMessage: String {
        if incomeRows.isEmpty {
            return "No income yet. Tap Sync to pull from the portal."
        }
        return "No income in \(periodLabel.lowercased())."
    }

    private func toggleHidden(_ card: String) {
        if hiddenCards.contains(card) {
            hiddenCards.remove(card)
        } else {
            hiddenCards.insert(card)
        }
    }

    // MARK: - Import / sync

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                try upsertTransactions(from: data)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    // How the Sync Status row is colored / which SF Symbol to show
    private enum SyncStatusKind {
        case idle
        case running
        case success
        case warning
        case failure

        var systemImage: String {
            switch self {
            case .idle: return "ellipsis.circle"
            case .running: return "arrow.triangle.2.circlepath"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .running: return .accentColor
            case .success: return .green
            case .warning: return .orange
            case .failure: return .red
            }
        }
    }

    // Update the Sync Status section (call from MainActor / UI path)
    @MainActor
    private func setSyncStatus(_ kind: SyncStatusKind, title: String, detail: String = "") {
        showSyncStatus = true
        syncStatusKind = kind
        syncStatusTitle = title
        syncStatusDetail = detail
    }

    /// How much history to download after the Plaid bank pull
    private enum SyncScope {
        /// Current + previous calendar month only (default quick sync)
        case recent
        /// Unfiltered GET /api/transactions + GET /api/income (full portal tables)
        case everything

        var statusLabel: String {
            switch self {
            case .recent: return "recent months"
            case .everything: return "everything"
            }
        }
    }

    // Sync button flow:
    // 1) Ask the PC to pull from Plaid into SQLite (once; no fixed month)
    // 2) GET + upsert expenses (recent months, or all rows if scope == .everything)
    // 3) GET + upsert income the same way (separate stream; not in spend)
    // 4) If Plaid is rate-limited (429) or busy (409), still do those GETs
    // 5) Surface each step in Sync Status
    private func syncFromServer(scope: SyncScope = .recent) async {
        await MainActor.run {
            isSyncing = true
            setSyncStatus(
                .running,
                title: "Starting \(scope.statusLabel) sync…",
                detail: "Connecting to \(apiBaseURL)"
            )
        }

        // Recent = two months; everything = no month filter on the GETs
        let months: [String]? = scope == .recent ? AppSettings.currentAndPreviousMonths() : nil
        let rangeLabel: String = {
            if let months {
                return months.joined(separator: ", ")
            }
            return "all rows (no month filter)"
        }()

        do {
            await MainActor.run {
                setSyncStatus(
                    .running,
                    title: "Plaid bank sync…",
                    detail: "Asking the server to pull latest data from linked banks"
                )
            }

            // Step 1: trigger Plaid → SQLite (may 429 under local cooldown)
            let plaidResult = try await requestPlaidSync()

            // Human-readable Plaid step for the final summary
            let plaidLine: String
            let plaidWasWarning: Bool
            switch plaidResult {
            case .synced:
                plaidLine = "Plaid: synced successfully"
                plaidWasWarning = false
            case .rateLimited(let retryHint):
                plaidLine = "Plaid: rate-limited (skipped bank pull)"
                    + (retryHint.map { " — \($0)" } ?? "")
                plaidWasWarning = true
            case .busy:
                plaidLine = "Plaid: already running on server (skipped)"
                plaidWasWarning = true
            case .failed(let message):
                plaidLine = "Plaid: failed — \(message)"
                plaidWasWarning = true
            }

            await MainActor.run {
                setSyncStatus(
                    .running,
                    title: "Downloading expenses…",
                    detail: "\(plaidLine)\nScope: \(scope.statusLabel)\nFetching: \(rangeLabel)"
                )
            }

            // Step 2: expenses (month list or full table)
            let pulled = try await pullAndUpsertExpenses(months: months)
            let monthLines = pulled.map { "\($0.label): \($0.count) expense(s)" }.joined(separator: "\n")
            let totalRows = pulled.reduce(0) { $0 + $1.count }

            await MainActor.run {
                setSyncStatus(
                    .running,
                    title: "Downloading income…",
                    detail: "\(plaidLine)\nScope: \(scope.statusLabel)\nFetching: \(rangeLabel)"
                )
            }

            // Step 3: income stream — soft-fail so expenses still land
            let incomeResult = await pullAndUpsertIncomeSoft(months: months)
            let incomeLines: String
            let totalIncomeRows: Int
            let incomeWarning: String?
            switch incomeResult {
            case .ok(let pulled):
                incomeLines = pulled.map { "\($0.label): \($0.count) income" }.joined(separator: "\n")
                totalIncomeRows = pulled.reduce(0) { $0 + $1.count }
                incomeWarning = nil
            case .failed(let message):
                incomeLines = "Income pull failed"
                totalIncomeRows = 0
                incomeWarning = message
            }

            await MainActor.run {
                let hadWarning = plaidWasWarning || incomeWarning != nil
                let kind: SyncStatusKind = hadWarning ? .warning : .success
                let title: String
                if case .synced = plaidResult, incomeWarning == nil {
                    title = scope == .everything ? "Sync everything complete" : "Sync complete"
                } else if case .failed = plaidResult {
                    title = "Sync finished with Plaid error"
                } else if incomeWarning != nil {
                    title = "Sync complete (income issue)"
                } else {
                    title = "Sync complete (Plaid skipped)"
                }
                var detail = """
                Scope: \(scope.statusLabel)
                \(plaidLine)
                Expenses: \(totalRows) row(s)
                \(monthLines)
                Income: \(totalIncomeRows) row(s)
                \(incomeLines)
                """
                if let incomeWarning {
                    detail += "\nIncome error: \(incomeWarning)"
                }
                setSyncStatus(kind, title: title, detail: detail)
                isSyncing = false
            }
        } catch {
            await MainActor.run {
                setSyncStatus(
                    .failure,
                    title: "Sync failed",
                    detail: error.localizedDescription
                )
                isSyncing = false
                importError = error.localizedDescription
            }
        }
    }

    // GET expenses for each month, or one unfiltered GET when months == nil
    private func pullAndUpsertExpenses(months: [String]?) async throws -> [(label: String, count: Int)] {
        if let months {
            var results: [(label: String, count: Int)] = []
            for month in months {
                await MainActor.run {
                    setSyncStatus(
                        .running,
                        title: "Downloading expenses \(month)…",
                        detail: syncStatusDetail
                    )
                }
                let data = try await requestTransactionsJSON(month: month)
                let count = try await MainActor.run {
                    try upsertTransactions(from: data)
                }
                results.append((month, count))
            }
            return results
        }

        await MainActor.run {
            setSyncStatus(
                .running,
                title: "Downloading all expenses…",
                detail: syncStatusDetail
            )
        }
        let data = try await requestTransactionsJSON(month: nil)
        let count = try await MainActor.run {
            try upsertTransactions(from: data)
        }
        return [("all", count)]
    }

    private enum IncomePullResult {
        case ok([(label: String, count: Int)])
        case failed(String)
    }

    // GET income for each month, or one unfiltered GET when months == nil (soft-fail)
    private func pullAndUpsertIncomeSoft(months: [String]?) async -> IncomePullResult {
        do {
            if let months {
                var results: [(label: String, count: Int)] = []
                for month in months {
                    await MainActor.run {
                        setSyncStatus(
                            .running,
                            title: "Downloading income \(month)…",
                            detail: syncStatusDetail
                        )
                    }
                    let data = try await requestIncomeJSON(month: month)
                    let count = try await MainActor.run {
                        try upsertIncome(from: data)
                    }
                    results.append((month, count))
                }
                return .ok(results)
            }

            await MainActor.run {
                setSyncStatus(
                    .running,
                    title: "Downloading all income…",
                    detail: syncStatusDetail
                )
            }
            let data = try await requestIncomeJSON(month: nil)
            let count = try await MainActor.run {
                try upsertIncome(from: data)
            }
            return .ok([("all", count)])
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Outcome of POST /api/plaid/sync
    private enum PlaidSyncResult {
        // 2xx — Plaid ran (or completed); transactions loaded via GET months
        case synced
        // 429 PLAID_SYNC_* cooldown / hourly cap — ignore and still pull JSON
        case rateLimited(retryHint: String?)
        // 409 SYNC_IN_FLIGHT — another sync running; still pull JSON
        case busy
        // Other HTTP / server error message
        case failed(String)
    }

    // Base URL from Settings (UserDefaults), not a hardcoded constant
    private var apiBaseURL: String {
        AppSettings.serverBaseURL
    }

    // POST /api/plaid/sync — pulls banks into the PC database (all linked items)
    private func requestPlaidSync() async throws -> PlaidSyncResult {
        guard let url = URL(string: "\(apiBaseURL)/api/plaid/sync") else {
            return .failed("Bad Plaid sync URL. Check Settings.")
        }

        // No month field: let the server refresh Plaid broadly; we GET months next
        struct PlaidSyncBody: Encodable {
            let includeTransactions: Bool
            let unexportedOnly: Bool
            let includePending: Bool
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PlaidSyncBody(
                // We always GET current + previous month afterward
                includeTransactions: false,
                unexportedOnly: false,
                includePending: false
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // Rate limit: do not treat as fatal — caller will GET /api/transactions
        if status == 429 {
            // Prefer server message / retryAfterSec when present
            var hint: String?
            if let sec = json?["retryAfterSec"] as? Int {
                let minutes = max(1, (sec + 59) / 60)
                hint = "try again in ~\(minutes) min"
            } else if let error = json?["error"] as? String {
                hint = error
            } else if let retryAfter = http?.value(forHTTPHeaderField: "Retry-After"),
                      let sec = Int(retryAfter) {
                let minutes = max(1, (sec + 59) / 60)
                hint = "try again in ~\(minutes) min"
            }
            return .rateLimited(retryHint: hint)
        }
        // Sync already running — same fallback
        if status == 409 {
            return .busy
        }

        if !(200...299).contains(status) {
            if let error = json?["error"] as? String {
                return .failed(error)
            }
            return .failed("HTTP \(status)")
        }

        return .synced
    }

    // GET /api/transactions — optional month=YYYY-MM (nil = full expense table)
    private func requestTransactionsJSON(month: String?) async throws -> Data {
        var components = URLComponents(string: "\(apiBaseURL)/api/transactions")
        if let month {
            components?.queryItems = [URLQueryItem(name: "month", value: month)]
        }
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let scope = month.map { "month \($0)" } ?? "all"
            throw NSError(
                domain: "FinanceWidget",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server returned \(http.statusCode) for transactions (\(scope))"
                ]
            )
        }
        return data
    }

    // GET /api/income — optional month=YYYY-MM (nil = full income table; pending off by default)
    private func requestIncomeJSON(month: String?) async throws -> Data {
        var components = URLComponents(string: "\(apiBaseURL)/api/income")
        if let month {
            components?.queryItems = [URLQueryItem(name: "month", value: month)]
        }
        // includePending defaults to false on the server
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let scope = month.map { "month \($0)" } ?? "all"
            throw NSError(
                domain: "FinanceWidget",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server returned \(http.statusCode) for income (\(scope))"
                ]
            )
        }
        return data
    }

    // Returns how many expense rows were in the JSON payload (for Sync Status)
    @discardableResult
    private func upsertTransactions(from data: Data) throws -> Int {
        let export = try JSONDecoder().decode(ExportFile.self, from: data)

        for item in export.transactions {
            guard let date = Self.parseExportDate(item.date) else { continue }
            let targetId = item.transaction_id

            var descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.transactionId == targetId }
            )
            descriptor.fetchLimit = 1

            let categoryLocked = item.category_locked ?? false
            let multiplierLocked = item.multiplier_locked ?? false

            if let existing = try modelContext.fetch(descriptor).first {
                existing.title = item.vendor
                existing.amount = -item.amount
                existing.date = date
                // Server is source of truth after classify (locked fields preserved on Plaid sync)
                existing.category = item.category
                existing.paymentMethod = item.payment_method
                existing.multiplier = item.multiplier
                existing.categoryLocked = categoryLocked
                existing.multiplierLocked = multiplierLocked
                existing.overrideSource = item.override_source
            } else {
                modelContext.insert(
                    Transaction(
                        transactionId: item.transaction_id,
                        title: item.vendor,
                        amount: -item.amount,
                        date: date,
                        category: item.category,
                        paymentMethod: item.payment_method,
                        multiplier: item.multiplier,
                        categoryLocked: categoryLocked,
                        multiplierLocked: multiplierLocked,
                        overrideSource: item.override_source
                    )
                )
            }
        }

        try modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        return export.transactions.count
    }

    // Upsert income rows from IncomeRow JSON. Amounts stay positive (earned).
    // Read-only on the app side — no classify/edit/mark-exported API for income.
    @discardableResult
    private func upsertIncome(from data: Data) throws -> Int {
        let export = try JSONDecoder().decode(IncomeExportFile.self, from: data)
        let rows = export.rows

        for item in rows {
            // Skip non-income discriminators if a mixed payload ever appears
            if let kind = item.kind, kind != "income" { continue }
            guard !item.transaction_id.isEmpty,
                  let date = Self.parseExportDate(item.date) else { continue }

            let targetId = item.transaction_id
            var descriptor = FetchDescriptor<Income>(
                predicate: #Predicate { $0.transactionId == targetId }
            )
            descriptor.fetchLimit = 1

            // API amounts are always > 0; abs() guards against a bad row looking like spend
            let amount = abs(item.amount)
            let source = item.source.isEmpty ? (item.raw_name ?? "Income") : item.source
            let category = item.category.isEmpty ? "Other Income" : item.category
            let kind = item.kind ?? "income"
            let pending = item.pending ?? false

            if let existing = try modelContext.fetch(descriptor).first {
                existing.source = source
                existing.amount = amount
                existing.date = date
                existing.category = category
                existing.accountName = item.account_name
                existing.accountMask = item.account_mask
                existing.sourceInstitution = item.source_institution
                existing.rawName = item.raw_name
                existing.pfc = item.pfc
                existing.pending = pending
                existing.kind = kind
                existing.updatedAt = item.updated_at
            } else {
                modelContext.insert(
                    Income(
                        transactionId: targetId,
                        source: source,
                        amount: amount,
                        date: date,
                        category: category,
                        accountName: item.account_name,
                        accountMask: item.account_mask,
                        sourceInstitution: item.source_institution,
                        rawName: item.raw_name,
                        pfc: item.pfc,
                        pending: pending,
                        kind: kind,
                        updatedAt: item.updated_at
                    )
                )
            }
        }

        try modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        return rows.count
    }

    private static func parseExportDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

// MARK: - Income list row + detail (read-only — no classify API for income)

struct IncomeRowView: View {
    let income: Income

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: CategoryStyle.symbolName(for: income.category))
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 28, alignment: .center)
                .accessibilityLabel(income.category)

            VStack(alignment: .leading, spacing: 4) {
                // Display: source (employer / payer)
                Text(income.source)
                    .font(.body)
                Text("\(income.category) · \(income.accountDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(income.date, style: .date)
                    if income.pending {
                        Text("Pending")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(income.amount, format: .currency(code: "USD"))
                .foregroundStyle(.green)
        }
    }
}

struct IncomeDetailView: View {
    let income: Income

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: CategoryStyle.symbolName(for: income.category))
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(income.source)
                            .font(.title3.weight(.semibold))
                        Text(income.amount, format: .currency(code: "USD"))
                            .font(.title2.bold())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("Date") {
                    Text(income.date, style: .date)
                }
                LabeledContent("Category") {
                    Text(income.category)
                }
                if let accountName = income.accountName, !accountName.isEmpty {
                    LabeledContent("Account") {
                        HStack(spacing: 8) {
                            BankIconView(paymentMethod: income.iconKey, size: 24)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(accountName)
                                if let mask = income.accountMask, !mask.isEmpty {
                                    Text("···\(mask)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } else if let institution = income.sourceInstitution, !institution.isEmpty {
                    LabeledContent("Institution") {
                        HStack(spacing: 8) {
                            BankIconView(paymentMethod: institution, size: 24)
                            Text(institution)
                        }
                    }
                }
                if income.pending {
                    LabeledContent("Status") {
                        Text("Pending")
                            .foregroundStyle(.orange)
                    }
                }
                if let rawName = income.rawName, !rawName.isEmpty, rawName != income.source {
                    LabeledContent("Bank description") {
                        Text(rawName)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let pfc = income.pfc, !pfc.isEmpty {
                    LabeledContent("Plaid category") {
                        Text(pfc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("ID") {
                    Text(income.transactionId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("Income is separate from expenses and is not included in Total Spend, category charts, or budget export. Read-only from the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Income")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Transaction.self, Income.self], inMemory: true)
}
