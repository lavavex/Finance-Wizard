//
//  ContentView.swift
//  Finance Wizard
//
//  Main app UI after onboarding: tab bar (Transactions, Accounts, Budget, Recurring, Settings),
//  the full Transactions tab (filters, import, Plaid sync), and income row/detail views.
//

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import WidgetKit

// MARK: - API / file decode shapes

/// One expense row as it appears in a JSON export file (snake_case keys from the server era).
struct ImportedTransaction: Decodable {
    let transaction_id: String
    let date: String
    let vendor: String
    let category: String
    let amount: Double
    let payment_method: String
    // Present after classify / lock on finance-sync (optional for older exports).
    let category_locked: Bool?
    let override_source: String?
}

/// Top-level JSON object: { "transactions": [ ... ] }.
struct ExportFile: Decodable {
    let transactions: [ImportedTransaction]
}

// Optional income array for offline JSON imports (legacy finance-sync shape still accepted)
/// One income row from a JSON export (amounts are positive “earned” money).
struct ImportedIncome: Decodable {
    let transaction_id: String
    let date: String
    let month_name: String?
    let year: Int?
    let source: String
    let category: String
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

/// Wrapper around an income export file; several top-level keys are optional for flexibility.
struct IncomeExportFile: Decodable {
    let ok: Bool?
    let kind: String?
    let count: Int?
    let total: Double?
    let categories: [String]?
    let income: [ImportedIncome]?

    var rows: [ImportedIncome] { income ?? [] }
}

// MARK: - Root tabs

/// Which main tab is selected.
private enum AppTab: Hashable {
    case transactions
    case accounts
    case budget
    case subscriptions
    case settings
}

/// Root of the main UI: a TabView with lazy-loaded secondary tabs for faster launch.
struct ContentView: View {
    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false
    @State private var selectedTab: AppTab = .transactions
    /// Only build heavy tabs after the user opens them (first switch is still work; launch is not).
    @State private var loadedTabs: Set<AppTab> = [.transactions]
    @State private var showAsk = false

    /// Custom Binding so selecting a tab also marks it “loaded” before assignment.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                loadedTabs.insert(newValue)
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            // First tab always built at launch (not lazy).
            AllTransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
                .tag(AppTab.transactions)

            lazyTab(.accounts) {
                CardsView()
            }
            .tabItem { Label("Accounts", systemImage: "building.columns") }
            .tag(AppTab.accounts)

            lazyTab(.budget) {
                BudgetView()
            }
            .tabItem { Label("Budget", systemImage: "chart.pie.fill") }
            .tag(AppTab.budget)

            lazyTab(.subscriptions) {
                SubscriptionsView()
            }
            .tabItem { Label("Recurring", systemImage: "repeat.circle") }
            .tag(AppTab.subscriptions)

            lazyTab(.settings) {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .environment(\.screenshotPrivacy, screenshotPrivacy)
        // Opening a .fwbackup from Files jumps to Settings (where restore UI lives).
        .onReceive(NotificationCenter.default.publisher(for: PlaidConnectionBackup.openFileNotification)) { _ in
            loadedTabs.insert(.settings)
            selectedTab = .settings
        }
        // NOTE: an earlier attempt used .safeAreaInset(edge: .bottom) here to avoid the
        // hard-coded offset. On the iOS 26 floating tab bar that placed the button on top
        // of the Settings tab item, so it is back to an overlay. The offset clears the
        // floating bar; the trade-off is that the button still floats over list content.
        .overlay(alignment: .bottomTrailing) {
            Button {
                showAsk = true
            } label: {
                Image(systemName: "apple.intelligence")
                    .font(.title)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .pink, .purple, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .accessibilityLabel("Ask")
            .buttonStyle(.glass)
            .padding(.trailing, 20)
            .padding(.bottom, 100)
        }
        .sheet(isPresented: $showAsk) {
            OnDeviceAIChatView()
        }
    }

    @ViewBuilder
    private func lazyTab<Content: View>(
        _ tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if loadedTabs.contains(tab) {
            content()
        } else {
            // Placeholder until first selection — avoids building all tabs at launch.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - All transactions tab

/// Primary “Finances” screen: period filters, totals, income + expense lists, import & Plaid sync.
struct AllTransactionsView: View {
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Query private var bankAccounts: [BankAccount]
    @Environment(\.modelContext) private var modelContext

    @State private var isImporting = false
    @State private var importContentTypes: [UTType] = [.json]
    @State private var importMode: ImportMode = .json
    @State private var importError: String?
    @State private var importStatusMessage: String?
    @State private var isSyncing = false

    @State private var syncStatusTitle: String = ""
    @State private var syncStatusDetail: String = ""
    @State private var syncStatusKind: SyncStatusKind = .idle
    /// Keeps the status section visible after a run until the next Sync.
    @State private var showSyncStatus = false
    @State private var showLinkSheet = false

    // Same filter concepts as the widget (period + sort + search).
    @State private var period: SnapshotPeriod = .month
    /// Which week/month to show (any day in that period; months use month start).
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    @State private var searchText: String = ""
    /// Heavy scan (review queue) — not computed every body pass.
    @State private var reviewCount: Int = 0

    private var visibleTransactions: [Transaction] {
        let base = TransactionAnalytics.filter(
            transactions,
            period: period,
            referenceDate: referenceDate,
            excludedCards: [],
            sort: sort
        )
        return TransactionSearch.filter(base, query: searchText, accounts: bankAccounts)
    }

    // Period-only set for totals — ignores search so totals stay “whole period”.
    private var periodTransactions: [Transaction] {
        TransactionAnalytics.inPeriod(transactions, period: period, referenceDate: referenceDate)
    }

    // Income for the same period (never mixed into spend).
    private var periodIncome: [Income] {
        IncomeAnalytics.inPeriod(incomeRows, period: period, referenceDate: referenceDate)
    }

    private var visibleIncome: [Income] {
        let base = IncomeAnalytics.filter(
            incomeRows,
            period: period,
            referenceDate: referenceDate,
            sort: sort
        )
        return IncomeSearch.filter(base, query: searchText)
    }

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    // Expenses only (all cards in the period).
    private var totalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
    }

    // Money earned in the period (always positive).
    private var totalIncome: Double {
        IncomeAnalytics.totalEarned(in: periodIncome)
    }

    private var periodNet: Double {
        totalIncome - totalSpend
    }

    var body: some View {
        NavigationStack {
            List {
                if let importStatusMessage {
                    Section("Import") {
                        Text(importStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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

                // Totals — spend from expenses only; income is a separate stream.
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
                            MoneyText(totalSpend)
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
                        MoneyText(totalIncome)
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
                        MoneyText(periodNet)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(periodNet >= 0 ? .green : .primary)
                    }
                    Text("\(periodTransactions.count) expenses · \(periodIncome.count) income in \(periodLabel.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        ReviewQueueView()
                    } label: {
                        HStack {
                            Label("Needs review", systemImage: "checklist")
                            Spacer()
                            if reviewCount > 0 {
                                Text("\(reviewCount)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Clear")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Tools")
                }

                Section("Income") {
                    if visibleIncome.isEmpty {
                        Text(incomeEmptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleIncome) { row in
                            NavigationLink {
                                IncomeDetailView(income: row, bankAccounts: bankAccounts)
                            } label: {
                                // Match income row to a known bank account (mask or name).
                                let matched = bankAccounts.first { account in
                                    if let mask = row.accountMask, let am = account.mask, mask == am {
                                        return true
                                    }
                                    if let name = row.accountName, account.matchesPaymentMethod(name) {
                                        return true
                                    }
                                    return false
                                }
                                IncomeRowView(
                                    income: row,
                                    institutionId: matched?.institutionId,
                                    institutionName: matched?.institutionName ?? row.sourceInstitution,
                                    accountLabel: matched?.displayName
                                )
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
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                let matched = BankAccount.matching(
                                    paymentMethod: transaction.paymentMethod,
                                    in: bankAccounts
                                )
                                TransactionRowView(
                                    transaction: transaction,
                                    institutionId: matched?.institutionId,
                                    institutionName: matched?.institutionName
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Finances")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Title, category, amount, last 4"
            )
            .refreshable {
                await syncFromPlaid(resetCursors: false)
            }
            .task {
                AppleCardAccount.ensureIfNeeded(in: modelContext, transactions: transactions)
                InstitutionLogoCache.warmMemory(accounts: bankAccounts)
                InstitutionLogoCache.prefetch(accounts: bankAccounts)
                refreshToolStats()
            }
            .onChange(of: transactions.count) { _, _ in
                refreshToolStats()
            }
            .onChange(of: bankAccounts.count) { _, _ in
                InstitutionLogoCache.warmMemory(accounts: bankAccounts)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Menu {
                            Button {
                                Task { await syncFromPlaid(resetCursors: false, forceRefresh: false) }
                            } label: {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                Task { await syncFromPlaid(resetCursors: false, forceRefresh: true) }
                            } label: {
                                Label("Force bank refresh", systemImage: "bolt.horizontal.circle")
                            }
                            Button {
                                Task { await syncFromPlaid(resetCursors: true, forceRefresh: false) }
                            } label: {
                                Label("Full re-sync", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button {
                                showLinkSheet = true
                            } label: {
                                Label("Link bank account", systemImage: "building.columns")
                            }
                        } label: {
                            Text("Sync")
                        }
                        .disabled(isSyncing)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        showTitle: false
                    )

                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TransactionSort.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    Menu {
                        Button {
                            importMode = .json
                            importContentTypes = [.json]
                            isImporting = true
                        } label: {
                            Label("JSON export…", systemImage: "doc.text")
                        }
                        Button {
                            importMode = .appleCardCSV
                            // CSV picker: commaSeparatedText, plainText, and .csv (whichever UTTypes exist).
                            importContentTypes = [.commaSeparatedText, .plainText, UTType(filenameExtension: "csv")].compactMap { $0 }
                            isImporting = true
                        } label: {
                            Label("Apple Card CSV…", systemImage: "apple.logo")
                        }
                    } label: {
                        Text("Import")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: importContentTypes,
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
            .sheet(isPresented: $showLinkSheet) {
                PlaidLinkSheet { result in
                    if case .failure(let error) = result {
                        importError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if transactions.isEmpty {
            return "No expenses yet. Link a bank in Settings, then tap Sync."
        }
        if periodTransactions.isEmpty {
            return "No expenses in \(periodLabel.lowercased())."
        }
        return "No expenses match your search."
    }

    private var incomeEmptyMessage: String {
        if incomeRows.isEmpty {
            return "No income yet. Tap Sync after linking a bank."
        }
        return "No income in \(periodLabel.lowercased())."
    }

    // MARK: - Import / sync

    /// Which file kind the import picker is targeting right now.
    private enum ImportMode {
        case json
        case appleCardCSV
    }

    /// Handles the document picker’s Result: security-scope access, then CSV or JSON path.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // Security-scoped URLs need start/stop access for files outside the sandbox.
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent.lowercased()
                let mode = importMode
                // Auto-detect by extension when the picker is ambiguous.
                if mode == .appleCardCSV || name.hasSuffix(".csv") {
                    let report = try AppleCardCSVImporter.importCSV(
                        data: data,
                        modelContext: modelContext
                    )
                    WidgetCenter.shared.reloadAllTimelines()
                    importStatusMessage = report.summary
                    importError = nil
                } else {
                    let count = try upsertTransactions(from: data)
                    importStatusMessage = "Imported \(count) transaction(s) from JSON."
                    importError = nil
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

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

    @MainActor
    private func setSyncStatus(_ kind: SyncStatusKind, title: String, detail: String = "") {
        showSyncStatus = true
        syncStatusKind = kind
        syncStatusTitle = title
        syncStatusDetail = detail
    }

    /// Pull transactions directly from the user’s Plaid developer account.
    /// - Parameter resetCursors: if true, re-download full history for each Item.
    /// - Parameter forceRefresh: call `/transactions/refresh` first (on-demand bank pull).
    private func syncFromPlaid(resetCursors: Bool, forceRefresh: Bool = false) async {
        await MainActor.run {
            isSyncing = true
            let title: String = {
                if resetCursors { return "Full re-sync…" }
                if forceRefresh { return "Force refreshing banks…" }
                return "Syncing with Plaid…"
            }()
            setSyncStatus(
                .running,
                title: title,
                detail: PlaidCredentialsStore.isConfigured
                    ? "Environment: \(PlaidCredentialsStore.environment.displayName)"
                    : "Missing credentials"
            )
        }

        do {
            let report = try await PlaidSyncEngine.syncAll(
                modelContext: modelContext,
                resetCursors: resetCursors,
                includePending: true,
                forceRefresh: forceRefresh
            ) { message in
                Task { @MainActor in
                    setSyncStatus(.running, title: "Syncing…", detail: message)
                }
            }

            await MainActor.run {
                let kind: SyncStatusKind = report.warnings.isEmpty ? .success : .warning
                setSyncStatus(
                    kind,
                    title: report.warnings.isEmpty ? "Sync complete" : "Sync finished with warnings",
                    detail: report.summary
                )
                isSyncing = false
                refreshToolStats()
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

    /// Review queue count is expensive; never run it in `body`.
    @MainActor
    private func refreshToolStats() {
        let txModels = transactions
        let accounts = bankAccounts

        // Review queue needs live models (reasons attach to Transaction rows).
        // Yield first so the current scroll frame can finish.
        Task(priority: .utility) { @MainActor in
            await Task.yield()
            reviewCount = ReviewQueueAnalytics.count(
                in: txModels,
                accounts: accounts
            )
        }
    }

    // Offline JSON import (legacy finance-sync export shape still works).
    @discardableResult
    private func upsertTransactions(from data: Data) throws -> Int {
        let export = try JSONDecoder().decode(ExportFile.self, from: data)

        for item in export.transactions {
            guard let date = Self.parseExportDate(item.date) else { continue }
            // #Predicate must capture a local let, not `item.transaction_id`.
            let targetId = item.transaction_id

            var descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate<Transaction> { row in
                    row.transactionId == targetId
                }
            )
            descriptor.fetchLimit = 1

            // Missing lock flags in older exports → treat as unlocked.
            let categoryLocked = item.category_locked ?? false

            // Export amounts are positive spend; the model stores signed spend (negative).
            if let existing = try modelContext.fetch(descriptor).first {
                existing.title = item.vendor
                existing.amount = -item.amount
                existing.date = date
                // Respect user locks so Sync / re-import won’t overwrite the category.
                if !existing.isCategoryLocked {
                    existing.category = item.category
                }
                existing.paymentMethod = item.payment_method
                existing.categoryLocked = categoryLocked
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
                        categoryLocked: categoryLocked,
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
            // Skip non-income discriminators if a mixed payload ever appears.
            if let kind = item.kind, kind != "income" { continue }
            guard !item.transaction_id.isEmpty,
                  let date = Self.parseExportDate(item.date) else { continue }

            let targetId = item.transaction_id
            var descriptor = FetchDescriptor<Income>(
                predicate: #Predicate<Income> { row in
                    row.transactionId == targetId
                }
            )
            descriptor.fetchLimit = 1

            // API amounts are always > 0; abs() guards against a bad row looking like spend.
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

    /// Parse export date strings like "2026-07-15" into Date (UTC Gregorian, POSIX locale).
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

/// One income line in the Transactions list (icon, source, category, amount).
struct IncomeRowView: View {
    let income: Income
    var institutionId: String? = nil
    var institutionName: String? = nil
    var accountLabel: String? = nil

    @Environment(\.screenshotPrivacy) private var screenshotPrivacy

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: CategoryStyle.symbolName(for: income.category))
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 28, alignment: .center)
                    .accessibilityLabel(income.category)
                if institutionId != nil || institutionName != nil || !income.iconKey.isEmpty {
                    BankIconView(
                        paymentMethod: income.iconKey,
                        size: 14,
                        institutionId: institutionId,
                        institutionName: institutionName ?? income.sourceInstitution
                    )
                    .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(income.source)
                    .font(.body)
                Text(
                    "\(income.category) · \(ScreenshotPrivacy.cardText(accountLabel ?? income.accountDisplay, privacy: screenshotPrivacy))"
                )
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
            MoneyText(income.amount)
                .foregroundStyle(.green)
        }
    }
}

/// Read-only detail screen for a single income row (Form of labeled fields).
struct IncomeDetailView: View {
    let income: Income
    var bankAccounts: [BankAccount] = []

    /// Linked BankAccount for logos when names/masks match.
    private var linkedAccount: BankAccount? {
        bankAccounts.first { account in
            if let mask = income.accountMask, let am = account.mask, mask == am { return true }
            if let name = income.accountName, account.matchesPaymentMethod(name) { return true }
            return false
        }
    }

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
                        MoneyText(income.amount)
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
                            BankIconView(
                                paymentMethod: income.iconKey,
                                size: 24,
                                institutionId: linkedAccount?.institutionId,
                                institutionName: linkedAccount?.institutionName ?? income.sourceInstitution
                            )
                            VStack(alignment: .trailing, spacing: 2) {
                                CardText(accountName)
                                if let mask = income.accountMask, !mask.isEmpty {
                                    CardText("···\(mask)")
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
                            BankIconView(
                                paymentMethod: institution,
                                size: 24,
                                institutionId: linkedAccount?.institutionId,
                                institutionName: linkedAccount?.institutionName ?? institution
                            )
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
                // Only show bank description when it differs from the friendly source.
                if let rawName = income.rawName, !rawName.isEmpty, rawName != income.source {
                    LabeledContent("Bank description") {
                        Text(rawName)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let pfc = income.pfc, !pfc.isEmpty {
                    LabeledContent("Bank category") {
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

        }
        .navigationTitle("Income")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Transaction.self, Income.self], inMemory: true)
}
