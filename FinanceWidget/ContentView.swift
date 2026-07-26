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
    @State private var sort: TransactionSort = .dateNewest
    // Cards hidden from the list (does not change Total Spend header)
    @State private var hiddenCards: Set<String> = []

    // Rows for the list: period + hide cards + sort
    private var visibleTransactions: [Transaction] {
        TransactionAnalytics.filter(
            transactions,
            period: period,
            excludedCards: hiddenCards,
            sort: sort
        )
    }

    // Period-only set (for totals — hide cards does not apply)
    private var periodTransactions: [Transaction] {
        TransactionAnalytics.inPeriod(transactions, period: period)
    }

    // Big number: all cards in the period
    private var totalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
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

                // Total Spend — tap to open category charts
                Section {
                    NavigationLink {
                        CategorySpendView(period: period)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Spend")
                                    .font(.headline)
                                Text(period.displayName)
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
                    Text("\(periodTransactions.count) transactions in period")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !hiddenCards.isEmpty {
                        Text("Hiding \(hiddenCards.count) card(s) from the list only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Transactions") {
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
                    Button {
                        Task { await syncFromServer() }
                    } label: {
                        if isSyncing {
                            // Show progress in the toolbar while a sync is running
                            ProgressView()
                        } else {
                            Text("Sync")
                        }
                    }
                    .disabled(isSyncing)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Period
                    Menu {
                        Picker("Period", selection: $period) {
                            ForEach(SnapshotPeriod.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "calendar")
                    }

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
            return "No transactions yet. Tap Sync or Import."
        }
        if periodTransactions.isEmpty {
            return "No transactions in \(period.displayName.lowercased())."
        }
        return "All cards in this period are hidden. Show some cards to see the list."
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

    // Sync button flow:
    // 1) Ask the PC to pull from Plaid into SQLite (once; no fixed month)
    // 2) GET + upsert current month AND previous month
    // 3) If Plaid is rate-limited (429) or busy (409), still do those GETs
    // 4) Surface each step in Sync Status
    private func syncFromServer() async {
        await MainActor.run {
            isSyncing = true
            setSyncStatus(.running, title: "Starting sync…", detail: "Connecting to \(apiBaseURL)")
        }

        // Always pull these two calendar months (not hardcoded)
        let months = AppSettings.currentAndPreviousMonths()

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
                    title: "Downloading transactions…",
                    detail: "\(plaidLine)\nFetching months: \(months.joined(separator: ", "))"
                )
            }

            // Step 2: always try to load months (even if Plaid was limited/failed)
            let pulled = try await pullAndUpsertMonths(months)
            let monthLines = pulled.map { "\($0.month): \($0.count) row(s)" }.joined(separator: "\n")
            let totalRows = pulled.reduce(0) { $0 + $1.count }

            await MainActor.run {
                let kind: SyncStatusKind = plaidWasWarning ? .warning : .success
                let title: String
                if case .synced = plaidResult {
                    title = "Sync complete"
                } else if case .failed = plaidResult {
                    title = "Sync finished with Plaid error"
                } else {
                    title = "Sync complete (Plaid skipped)"
                }
                setSyncStatus(
                    kind,
                    title: title,
                    detail: "\(plaidLine)\nLoaded \(totalRows) transaction row(s) into the app:\n\(monthLines)"
                )
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

    // GET each month and merge into SwiftData; returns per-month counts for status UI
    private func pullAndUpsertMonths(_ months: [String]) async throws -> [(month: String, count: Int)] {
        var results: [(month: String, count: Int)] = []
        for month in months {
            await MainActor.run {
                setSyncStatus(
                    .running,
                    title: "Downloading \(month)…",
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

    // GET /api/transactions?month=YYYY-MM — SQLite snapshot (no Plaid call, no rate limit)
    private func requestTransactionsJSON(month: String) async throws -> Data {
        var components = URLComponents(string: "\(apiBaseURL)/api/transactions")
        components?.queryItems = [
            URLQueryItem(name: "month", value: month)
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "FinanceWidget",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server returned \(http.statusCode) for transactions (\(month))"
                ]
            )
        }
        return data
    }

    // Returns how many rows were in the JSON payload (for Sync Status)
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

    private static func parseExportDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Transaction.self, inMemory: true)
}
