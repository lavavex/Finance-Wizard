//
//  PlaidConnectionBackup.swift
//  Finance Wizard
//
//  Password-encrypted full app backup / restore (portable after factory reset).
//
//  Includes:
//  • Plaid developer credentials (client_id, secret, environment, redirect)
//  • Linked bank Items (access tokens + cursors + metadata)
//  • SwiftData: transactions, income, bank accounts, card payments, budget, recurring, payoff plans
//  • Prefs: card nicknames, vendor learn-rules, card benefits profiles, screenshot privacy
//  • Auto bags: UserDefaults under plaid./card./settings. + App Group logo files
//
//  Crypto (backup format v1 — portable, password-based):
//  • Random 256-bit data key (DEK) encrypts the payload with AES-256-GCM
//  • Password → PBKDF2-HMAC-SHA512 (high cost) → HKDF-SHA512 → wrap key (KEK)
//  • KEK wraps the DEK with AES-256-GCM (password never encrypts bulk data directly)
//  • 32-byte random salt; authenticated encryption throughout (tamper-evident)
//  • File type: .fwbackup (UTType net.roberth.FinanceWizard.backup)
//
//  Restore safety (default = safeMerge):
//  • NEVER overwrites an existing access_token already on this device
//  • NEVER overwrites non-empty Plaid API secret / client_id already configured
//  • Upserts app data by unique ids; preserves local category/rail locks
//  • Never deletes local-only banks or rows that are absent from the backup
//
//  Use replaceConnections when the backup’s tokens/keys should win.
//  Use wipeThenRestore to delete local SwiftData + prefs + logos + tokens first,
//  so data added after an older backup (or after new models shipped) is gone.
//

import Foundation
import CryptoKit
import CommonCrypto
import Security
import SwiftData
import WidgetKit
import UniformTypeIdentifiers

// MARK: - Public API

enum PlaidConnectionBackup {
    /// Filename extension registered with the system (Files / cloud apps → Open in).
    static let fileExtension = "fwbackup"
    /// Exported UTI — must match Info.plist `UTExportedTypeDeclarations` / document types.
    static let utiIdentifier = "net.roberth.FinanceWizard.backup"
    /// Marker inside the encrypted envelope JSON.
    static let formatID = "financewizard.app-backup"
    /// Single public format version (payload + envelope). This is backup v1.
    static let formatVersion = 1
    /// PBKDF2-HMAC-SHA512 rounds (above OWASP’s SHA-512 baseline).
    static let pbkdf2Iterations: UInt32 = 1_000_000
    static let saltByteCount = 32
    static let keyByteCount = 32
    static let minimumPasswordLength = 8
    static let kdfID = "pbkdf2-sha512-hkdf-sha512"
    static let cipherID = "aes-256-gcm"
    /// Notification when a `.fwbackup` is opened from Files / another app.
    static let openFileNotification = Notification.Name("financewizard.openBackupFile")

    /// UTType for document picker / fileImporter (falls back to extension lookup).
    static var contentType: UTType {
        if let t = UTType(utiIdentifier) { return t }
        if let t = UTType(filenameExtension: fileExtension) { return t }
        return .data
    }

    /// Types accepted when picking or receiving a backup file.
    static var importContentTypes: [UTType] {
        [contentType, .data]
    }

    /// True when the URL looks like a Finance Wizard backup (by extension).
    static func isBackupFileURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Delete SwiftData, linked banks, prefs, and logos on this device.
    /// Public for wipe-then-restore and the Debug menu. Does not touch the Plaid Dashboard.
    @MainActor
    static func wipeLocalAppData(modelContext: ModelContext) throws {
        try SharedStore.wipeAllModels(in: modelContext)
        try modelContext.save()
        PlaidItemStore.removeAll()
        AppPreferenceBackup.wipe()
        // Nicknames are cached in memory; the wipe replaced UserDefaults underneath it.
        CardLabelStore.resetMemoryCache()
        InstitutionLogoCache.wipeAllLogoFiles()
        AskStore.wipe()
    }

    // MARK: Restore policy

    /// How restore treats credentials and access tokens already on the device.
    enum RestorePolicy: String, CaseIterable, Identifiable, Sendable {
        /// Default. Existing tokens and configured credentials are left alone.
        case safeMerge
        /// Backup wins for credentials + every Item token (still never deletes local-only Items).
        case replaceConnections
        /// Deletes local SwiftData, prefs, logos, and bank tokens, then restores the backup.
        case wipeThenRestore

        var id: String { rawValue }

        var title: String {
            switch self {
            case .safeMerge: return "Safe merge (recommended)"
            case .replaceConnections: return "Replace connections from backup"
            case .wipeThenRestore: return "Wipe device, then restore"
            }
        }

        var detail: String {
            switch self {
            case .safeMerge:
                return "Adds missing banks and data only. Will not change access tokens or API keys already on this phone."
            case .replaceConnections:
                return "Overwrites Plaid API keys and access tokens with the backup’s copies. Use only if you want the backup to win."
            case .wipeThenRestore:
                return "Deletes everything on this phone first (including data added after this backup was made), then restores the backup as the only copy."
            }
        }

        var wipesLocalData: Bool { self == .wipeThenRestore }
    }

    // MARK: Payload

    struct RestorePlan: Equatable, Sendable {
        var policy: RestorePolicy
        var credentialsAction: String
        var itemsToAdd: [String]
        var itemsPreserved: [String]
        var itemsTokenReplaced: [String]
        var transactionCount: Int
        var incomeCount: Int
        var bankAccountCount: Int
        var paymentCount: Int
        var recurringCount: Int
        var budgetPlanCount: Int
        var payoffPlanCount: Int
        var cardLabelCount: Int
        var vendorRuleCount: Int
        var isConnectionsOnly: Bool

        var itemsToAddCount: Int { itemsToAdd.count }
        var itemsPreservedCount: Int { itemsPreserved.count }
        var itemsTokenReplacedCount: Int { itemsTokenReplaced.count }
    }

    struct RestoreSummary: Equatable, Sendable {
        var policy: RestorePolicy
        var credentialsWritten: Bool
        var credentialsSkipped: Bool
        var itemsAdded: Int
        var itemsPreserved: Int
        var itemsTokenReplaced: Int
        var transactionsUpserted: Int
        var incomeUpserted: Int
        var bankAccountsUpserted: Int
        var paymentsUpserted: Int
        var recurringUpserted: Int
        var budgetPlansUpserted: Int
        var payoffPlansUpserted: Int
        var environment: String
        var institutionNamesAdded: [String]
    }

    // MARK: Capture

    @MainActor
    static func capturePayload(modelContext: ModelContext) throws -> Payload {
        let clientID = PlaidCredentialsStore.clientID
        let secret = PlaidCredentialsStore.secret
        let items = PlaidItemStore.loadItems()

        let txs = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let incomes = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        let payments = (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? []
        let streams = (try? modelContext.fetch(FetchDescriptor<RecurringStream>())) ?? []
        let plans = (try? modelContext.fetch(FetchDescriptor<BudgetPlan>())) ?? []
        let payoffs = (try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? []

        let hasAnything = !clientID.isEmpty || !secret.isEmpty || !items.isEmpty
            || !txs.isEmpty || !incomes.isEmpty || !accounts.isEmpty || !payments.isEmpty
            || !streams.isEmpty || !plans.isEmpty || !payoffs.isEmpty
            || !VendorRulesStore.load().isEmpty
            || !CardLabelStore.debugExportMap().isEmpty

        guard hasAnything else { throw BackupError.nothingToBackup }

        let redirectOverride: String = {
            guard PlaidCredentialsStore.hasCustomRedirectURI else { return "" }
            return PlaidCredentialsStore.redirectURI
        }()

        return Payload(
            version: formatVersion,
            createdAt: Date(),
            credentials: CredentialsSnapshot(
                clientID: clientID,
                secret: secret,
                environment: PlaidCredentialsStore.environment.rawValue,
                redirectURIOverride: redirectOverride
            ),
            items: items.map {
                ItemSnapshot(
                    id: $0.id,
                    accessToken: $0.accessToken,
                    institutionName: $0.institutionName,
                    accountNames: $0.accountNames,
                    transactionsCursor: $0.transactionsCursor,
                    linkedAt: $0.linkedAt,
                    errorCode: $0.errorCode,
                    errorMessage: $0.errorMessage,
                    lastStatusCheckAt: $0.lastStatusCheckAt
                )
            },
            transactions: txs.map(snapshot(transaction:)),
            income: incomes.map(snapshot(income:)),
            bankAccounts: accounts.map(snapshot(account:)),
            creditCardPayments: payments.map(snapshot(payment:)),
            recurringStreams: streams.map(snapshot(stream:)),
            budgetPlans: plans.map(snapshot(plan:)),
            payoffPlans: payoffs.map(snapshot(payoff:)),
            cardLabels: CardLabelStore.debugExportMap(),
            vendorRules: VendorRulesStore.load(),
            screenshotPrivacy: UserDefaults.standard.bool(forKey: ScreenshotPrivacy.storageKey),
            preferenceDefaults: AppPreferenceBackup.capture(),
            logoFiles: InstitutionLogoCache.exportAllLogoFiles()
        )
    }

    // MARK: Encrypt → file

    @MainActor
    static func exportEncryptedFile(password: String, modelContext: ModelContext) throws -> URL {
        try validatePassword(password)
        let payload = try capturePayload(modelContext: modelContext)
        let data = try encrypt(payload: payload, password: password)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "FinanceWizard-backup-\(stamp).\(fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Decrypt only (for plan preview)

    static func decryptPayload(from url: URL, password: String) throws -> Payload {
        try validatePassword(password)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        return try decrypt(envelopeData: data, password: password)
    }

    // MARK: Plan (no writes)

    @MainActor
    static func planRestore(payload: Payload, policy: RestorePolicy) -> RestorePlan {
        let existing = Dictionary(uniqueKeysWithValues: PlaidItemStore.loadItems().map { ($0.id, $0) })
        var toAdd: [String] = []
        var preserved: [String] = []
        var replaced: [String] = []

        for item in payload.items {
            let name = item.institutionName.isEmpty ? item.id : item.institutionName
            if let live = existing[item.id], !live.accessToken.isEmpty {
                switch policy {
                case .safeMerge:
                    preserved.append(name)
                case .replaceConnections:
                    replaced.append(name)
                case .wipeThenRestore:
                    replaced.append(name)
                }
            } else {
                toAdd.append(name)
            }
        }

        let credsConfigured = PlaidCredentialsStore.isConfigured
        let credentialsAction: String = {
            switch policy {
            case .safeMerge:
                if credsConfigured {
                    return "Keep current API keys (backup keys ignored)"
                }
                return PlaidCredentialsStore.clientID.isEmpty && PlaidCredentialsStore.secret.isEmpty
                    ? "Write API keys from backup (device has none)"
                    : "Fill only empty key fields from backup"
            case .replaceConnections, .wipeThenRestore:
                return "Overwrite API keys from backup"
            }
        }()

        let isConnectionsOnly =
            (payload.transactions?.isEmpty ?? true)
            && (payload.income?.isEmpty ?? true)
            && (payload.bankAccounts?.isEmpty ?? true)

        return RestorePlan(
            policy: policy,
            credentialsAction: credentialsAction,
            itemsToAdd: toAdd,
            itemsPreserved: preserved,
            itemsTokenReplaced: replaced,
            transactionCount: payload.transactions?.count ?? 0,
            incomeCount: payload.income?.count ?? 0,
            bankAccountCount: payload.bankAccounts?.count ?? 0,
            paymentCount: payload.creditCardPayments?.count ?? 0,
            recurringCount: payload.recurringStreams?.count ?? 0,
            budgetPlanCount: payload.budgetPlans?.count ?? 0,
            payoffPlanCount: payload.payoffPlans?.count ?? 0,
            cardLabelCount: payload.cardLabels?.count ?? 0,
            vendorRuleCount: payload.vendorRules?.count ?? 0,
            isConnectionsOnly: isConnectionsOnly
        )
    }

    // MARK: Apply

    @MainActor
    @discardableResult
    static func apply(
        payload: Payload,
        policy: RestorePolicy,
        modelContext: ModelContext
    ) throws -> RestoreSummary {
        guard payload.version == formatVersion else {
            throw BackupError.unsupportedVersion(payload.version)
        }

        if policy.wipesLocalData {
            try wipeLocalAppData(modelContext: modelContext)
        }

        let credResult = applyCredentials(payload.credentials, policy: policy)
        let itemResult = applyItems(payload.items, policy: policy)

        var txCount = 0
        var incomeCount = 0
        var accountCount = 0
        var paymentCount = 0
        var streamCount = 0
        var planCount = 0
        var payoffCount = 0

        if let rows = payload.transactions {
            txCount = upsertTransactions(rows, modelContext: modelContext)
        }
        if let rows = payload.income {
            incomeCount = upsertIncome(rows, modelContext: modelContext)
        }
        if let rows = payload.bankAccounts {
            accountCount = upsertBankAccounts(rows, modelContext: modelContext)
        }
        if let rows = payload.creditCardPayments {
            paymentCount = upsertPayments(rows, modelContext: modelContext)
        }
        if let rows = payload.recurringStreams {
            streamCount = upsertRecurring(rows, modelContext: modelContext)
        }
        if let rows = payload.budgetPlans {
            planCount = upsertBudgetPlans(rows, modelContext: modelContext)
        }
        if let rows = payload.payoffPlans {
            payoffCount = upsertPayoffPlans(rows, modelContext: modelContext)
        }

        if let labels = payload.cardLabels, !labels.isEmpty {
            mergeCardLabels(labels)
        }
        if let rules = payload.vendorRules, !rules.isEmpty {
            mergeVendorRules(rules)
        }
        if let privacy = payload.screenshotPrivacy {
            // Only set if true in backup or local never customized — always restore the value for full restore feel.
            UserDefaults.standard.set(privacy, forKey: ScreenshotPrivacy.storageKey)
        }

        if policy.wipesLocalData {
            if let prefs = payload.preferenceDefaults, !prefs.isEmpty {
                AppPreferenceBackup.restore(prefs)
                // Restore rewrites the whole defaults domain — drop the nickname cache.
                CardLabelStore.resetMemoryCache()
            }
            if let logos = payload.logoFiles, !logos.isEmpty {
                InstitutionLogoCache.importLogoFiles(logos)
            }
        }

        try modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()

        let credentialPoints = credResult.written ? 1 : 0
        let totalUseful = itemResult.added
            + itemResult.replaced
            + itemResult.preserved
            + txCount
            + incomeCount
            + accountCount
            + credentialPoints
        let hasLiveState = PlaidCredentialsStore.isConfigured || PlaidItemStore.hasLinkedItems
        guard totalUseful > 0 || hasLiveState else {
            throw BackupError.emptyPayload
        }

        return RestoreSummary(
            policy: policy,
            credentialsWritten: credResult.written,
            credentialsSkipped: credResult.skipped,
            itemsAdded: itemResult.added,
            itemsPreserved: itemResult.preserved,
            itemsTokenReplaced: itemResult.replaced,
            transactionsUpserted: txCount,
            incomeUpserted: incomeCount,
            bankAccountsUpserted: accountCount,
            paymentsUpserted: paymentCount,
            recurringUpserted: streamCount,
            budgetPlansUpserted: planCount,
            payoffPlansUpserted: payoffCount,
            environment: PlaidCredentialsStore.environment.displayName,
            institutionNamesAdded: itemResult.addedNames
        )
    }

    /// Decrypt + apply in one step (used when policy already chosen).
    @MainActor
    static func restore(
        from url: URL,
        password: String,
        policy: RestorePolicy,
        modelContext: ModelContext
    ) throws -> RestoreSummary {
        let payload = try decryptPayload(from: url, password: password)
        return try apply(payload: payload, policy: policy, modelContext: modelContext)
    }

    static func validatePassword(_ password: String) throws {
        if password.count < minimumPasswordLength {
            throw BackupError.passwordTooShort(minimum: minimumPasswordLength)
        }
    }
}

// MARK: - Credentials & Items (safe by default)

private extension PlaidConnectionBackup {
    struct CredApplyResult {
        var written: Bool
        var skipped: Bool
    }

    struct ItemApplyResult {
        var added: Int
        var preserved: Int
        var replaced: Int
        var addedNames: [String]
    }

    static func applyCredentials(_ creds: CredentialsSnapshot, policy: RestorePolicy) -> CredApplyResult {
        switch policy {
        case .safeMerge:
            var wrote = false
            if PlaidCredentialsStore.clientID.isEmpty, !creds.clientID.isEmpty {
                PlaidCredentialsStore.clientID = creds.clientID
                wrote = true
            }
            if PlaidCredentialsStore.secret.isEmpty, !creds.secret.isEmpty {
                PlaidCredentialsStore.secret = creds.secret
                wrote = true
            }
            // Environment only when credentials were incomplete before restore.
            if wrote {
                PlaidCredentialsStore.environment = PlaidEnvironment.fromStored(creds.environment)
            }
            if !PlaidCredentialsStore.hasCustomRedirectURI, !creds.redirectURIOverride.isEmpty {
                PlaidCredentialsStore.redirectURI = creds.redirectURIOverride
            }
            PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
            let skipped = PlaidCredentialsStore.isConfigured && !wrote
            return CredApplyResult(written: wrote, skipped: skipped || (!wrote && PlaidCredentialsStore.isConfigured))

        case .replaceConnections, .wipeThenRestore:
            if !creds.clientID.isEmpty {
                PlaidCredentialsStore.clientID = creds.clientID
            }
            if !creds.secret.isEmpty {
                PlaidCredentialsStore.secret = creds.secret
            }
            PlaidCredentialsStore.environment = PlaidEnvironment.fromStored(creds.environment)
            PlaidCredentialsStore.redirectURI = creds.redirectURIOverride
            PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
            return CredApplyResult(written: true, skipped: false)
        }
    }

    static func applyItems(_ snapshots: [ItemSnapshot], policy: RestorePolicy) -> ItemApplyResult {
        let existing = Dictionary(uniqueKeysWithValues: PlaidItemStore.loadItems().map { ($0.id, $0) })
        var added = 0
        var preserved = 0
        var replaced = 0
        var addedNames: [String] = []

        for snap in snapshots {
            let token = snap.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !snap.id.isEmpty, !token.isEmpty else { continue }
            let name = snap.institutionName.isEmpty ? snap.id : snap.institutionName

            if let live = existing[snap.id], !live.accessToken.isEmpty {
                switch policy {
                case .safeMerge:
                    // Hard guarantee: do not touch live token / cursor / metadata.
                    preserved += 1
                    continue
                case .replaceConnections, .wipeThenRestore:
                    let item = makeLinkedItem(from: snap, token: token)
                    PlaidItemStore.upsert(item)
                    replaced += 1
                }
            } else {
                let item = makeLinkedItem(from: snap, token: token)
                PlaidItemStore.upsert(item)
                added += 1
                addedNames.append(name)
            }
        }

        return ItemApplyResult(
            added: added,
            preserved: preserved,
            replaced: replaced,
            addedNames: addedNames
        )
    }

    static func makeLinkedItem(from snap: ItemSnapshot, token: String) -> PlaidLinkedItem {
        PlaidLinkedItem(
            id: snap.id,
            accessToken: token,
            institutionName: snap.institutionName,
            accountNames: snap.accountNames,
            transactionsCursor: snap.transactionsCursor,
            linkedAt: snap.linkedAt,
            errorCode: snap.errorCode,
            errorMessage: snap.errorMessage,
            lastStatusCheckAt: snap.lastStatusCheckAt
        )
    }
}

// MARK: - SwiftData upserts

private extension PlaidConnectionBackup {
    static func upsertTransactions(_ rows: [TransactionSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.transactionId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.transactionId] {
                mergeTransaction(live: live, from: row)
            } else {
                modelContext.insert(makeTransaction(from: row))
            }
            count += 1
        }
        return count
    }

    /// Preserve user locks on the device; fill other fields from backup.
    static func mergeTransaction(live: Transaction, from row: TransactionSnapshot) {
        let keepCategory = live.isCategoryLocked
        let keepRail = live.paymentRailLocked == true
        let keepSub = !(live.subscriptionCadenceOverride ?? "").isEmpty

        if !keepCategory {
            live.title = row.title
            live.category = row.category
            live.categoryLocked = row.categoryLocked
            live.overrideSource = row.overrideSource
        }
        live.amount = row.amount
        live.date = row.date
        live.paymentMethod = row.paymentMethod
        if !keepRail {
            live.plaidPaymentChannel = row.plaidPaymentChannel
            live.paymentRail = row.paymentRail
            live.paymentRailLocked = row.paymentRailLocked
        }
        if !keepSub {
            live.subscriptionCadenceOverride = row.subscriptionCadenceOverride
        }
        live.authorizedDate = row.authorizedDate ?? live.authorizedDate
        live.pendingTransactionId = row.pendingTransactionId ?? live.pendingTransactionId
        live.plaidAccountId = row.plaidAccountId ?? live.plaidAccountId
        live.merchantEntityId = row.merchantEntityId ?? live.merchantEntityId
        live.merchantName = row.merchantName ?? live.merchantName
        live.logoURL = row.logoURL ?? live.logoURL
        live.website = row.website ?? live.website
        live.pfcConfidence = row.pfcConfidence ?? live.pfcConfidence
        live.isPending = row.isPending ?? live.isPending
    }

    static func makeTransaction(from row: TransactionSnapshot) -> Transaction {
        Transaction(
            transactionId: row.transactionId,
            title: row.title,
            amount: row.amount,
            date: row.date,
            category: row.category,
            paymentMethod: row.paymentMethod,
            categoryLocked: row.categoryLocked ?? false,
            overrideSource: row.overrideSource,
            plaidPaymentChannel: row.plaidPaymentChannel,
            paymentRail: row.paymentRail,
            paymentRailLocked: row.paymentRailLocked ?? false,
            subscriptionCadenceOverride: row.subscriptionCadenceOverride,
            authorizedDate: row.authorizedDate,
            pendingTransactionId: row.pendingTransactionId,
            plaidAccountId: row.plaidAccountId,
            merchantEntityId: row.merchantEntityId,
            merchantName: row.merchantName,
            logoURL: row.logoURL,
            website: row.website,
            pfcConfidence: row.pfcConfidence,
            isPending: row.isPending
        )
    }

    static func upsertIncome(_ rows: [IncomeSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<Income>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.transactionId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.transactionId] {
                live.source = row.source
                live.amount = row.amount
                live.date = row.date
                live.category = row.category
                live.accountName = row.accountName
                live.accountMask = row.accountMask
                live.sourceInstitution = row.sourceInstitution
                live.rawName = row.rawName
                live.pfc = row.pfc
                live.pending = row.pending
                live.kind = row.kind
                live.updatedAt = row.updatedAt
            } else {
                modelContext.insert(
                    Income(
                        transactionId: row.transactionId,
                        source: row.source,
                        amount: row.amount,
                        date: row.date,
                        category: row.category,
                        accountName: row.accountName,
                        accountMask: row.accountMask,
                        sourceInstitution: row.sourceInstitution,
                        rawName: row.rawName,
                        pfc: row.pfc,
                        pending: row.pending,
                        kind: row.kind,
                        updatedAt: row.updatedAt
                    )
                )
            }
            count += 1
        }
        return count
    }

    static func upsertBankAccounts(_ rows: [BankAccountSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.accountId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.accountId] {
                live.itemId = row.itemId
                live.name = row.name
                live.officialName = row.officialName
                live.mask = row.mask
                live.type = row.type
                live.subtype = row.subtype
                live.institutionName = row.institutionName
                live.currentBalance = row.currentBalance
                live.availableBalance = row.availableBalance
                live.creditLimit = row.creditLimit
                live.institutionId = row.institutionId
                live.lastSyncedAt = row.lastSyncedAt
                live.isOverdue = row.isOverdue
                live.lastPaymentAmount = row.lastPaymentAmount
                live.lastPaymentDate = row.lastPaymentDate
                live.lastStatementIssueDate = row.lastStatementIssueDate
                live.lastStatementBalance = row.lastStatementBalance
                live.minimumPaymentAmount = row.minimumPaymentAmount
                live.nextPaymentDueDate = row.nextPaymentDueDate
                live.purchaseApr = row.purchaseApr
                live.cashApr = row.cashApr
                live.balanceTransferApr = row.balanceTransferApr
                live.specialApr = row.specialApr
                live.liabilitiesSyncedAt = row.liabilitiesSyncedAt
            } else {
                modelContext.insert(
                    BankAccount(
                        accountId: row.accountId,
                        itemId: row.itemId,
                        name: row.name,
                        officialName: row.officialName,
                        mask: row.mask,
                        type: row.type,
                        subtype: row.subtype,
                        institutionName: row.institutionName,
                        currentBalance: row.currentBalance,
                        availableBalance: row.availableBalance,
                        creditLimit: row.creditLimit,
                        institutionId: row.institutionId,
                        lastSyncedAt: row.lastSyncedAt,
                        isOverdue: row.isOverdue,
                        lastPaymentAmount: row.lastPaymentAmount,
                        lastPaymentDate: row.lastPaymentDate,
                        lastStatementIssueDate: row.lastStatementIssueDate,
                        lastStatementBalance: row.lastStatementBalance,
                        minimumPaymentAmount: row.minimumPaymentAmount,
                        nextPaymentDueDate: row.nextPaymentDueDate,
                        purchaseApr: row.purchaseApr,
                        cashApr: row.cashApr,
                        balanceTransferApr: row.balanceTransferApr,
                        specialApr: row.specialApr,
                        liabilitiesSyncedAt: row.liabilitiesSyncedAt
                    )
                )
            }
            count += 1
        }
        return count
    }

    static func upsertPayments(_ rows: [PaymentSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.transactionId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.transactionId] {
                live.amount = row.amount
                live.date = row.date
                live.cardName = row.cardName
                live.sourceAccount = row.sourceAccount
                live.title = row.title
                live.creditAccountId = row.creditAccountId
                live.institutionName = row.institutionName
            } else {
                modelContext.insert(
                    CreditCardPayment(
                        transactionId: row.transactionId,
                        amount: row.amount,
                        date: row.date,
                        cardName: row.cardName,
                        sourceAccount: row.sourceAccount,
                        title: row.title,
                        creditAccountId: row.creditAccountId,
                        institutionName: row.institutionName
                    )
                )
            }
            count += 1
        }
        return count
    }

    static func upsertRecurring(_ rows: [RecurringStreamSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<RecurringStream>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.streamId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.streamId] {
                live.itemId = row.itemId
                live.direction = row.direction
                live.streamDescription = row.streamDescription
                live.merchantName = row.merchantName
                live.averageAmount = row.averageAmount
                live.lastAmount = row.lastAmount
                live.frequency = row.frequency
                live.firstDate = row.firstDate
                live.lastDate = row.lastDate
                live.isActive = row.isActive
                live.transactionIdsJSON = try? JSONEncoder().encode(row.transactionIds)
                live.accountId = row.accountId
                live.updatedAt = row.updatedAt
            } else {
                modelContext.insert(
                    RecurringStream(
                        streamId: row.streamId,
                        itemId: row.itemId,
                        direction: row.direction,
                        streamDescription: row.streamDescription,
                        merchantName: row.merchantName,
                        averageAmount: row.averageAmount,
                        lastAmount: row.lastAmount,
                        frequency: row.frequency,
                        firstDate: row.firstDate,
                        lastDate: row.lastDate,
                        isActive: row.isActive,
                        transactionIds: row.transactionIds,
                        accountId: row.accountId,
                        updatedAt: row.updatedAt
                    )
                )
            }
            count += 1
        }
        return count
    }

    static func upsertBudgetPlans(_ rows: [BudgetPlanSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<BudgetPlan>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.planId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.planId] {
                // Prefer the newer plan by updatedAt.
                if row.updatedAt >= live.updatedAt {
                    live.monthlyLimit = row.monthlyLimit
                    live.categoryLimits = row.categoryLimits
                    live.expectedIncomeStreams = row.expectedIncome
                    live.updatedAt = row.updatedAt
                }
            } else {
                modelContext.insert(
                    BudgetPlan(
                        planId: row.planId,
                        monthlyLimit: row.monthlyLimit,
                        categoryLimits: row.categoryLimits,
                        expectedIncome: row.expectedIncome,
                        updatedAt: row.updatedAt
                    )
                )
            }
            count += 1
        }
        return count
    }

    static func upsertPayoffPlans(_ rows: [PayoffPlanSnapshot], modelContext: ModelContext) -> Int {
        let existing = ((try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? [])
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.planId, $0) })
        var count = 0
        for row in rows {
            if let live = byId[row.planId] {
                if row.updatedAt >= live.updatedAt {
                    live.kindRaw = row.kindRaw
                    live.name = row.name
                    live.accountId = row.accountId
                    live.paymentMethod = row.paymentMethod
                    live.originalAmount = row.originalAmount
                    live.remainingAmount = row.remainingAmount
                    live.monthlyPayment = row.monthlyPayment
                    live.monthlyFee = row.monthlyFee
                    live.aprPercent = row.aprPercent
                    live.startDate = row.startDate
                    live.endDate = row.endDate
                    live.termMonths = row.termMonths
                    live.linkedTransactionId = row.linkedTransactionId
                    live.notes = row.notes
                    live.isEnded = row.isEnded
                    live.lastAppliedStatementDate = row.lastAppliedStatementDate
                    live.createdAt = row.createdAt
                    live.updatedAt = row.updatedAt
                }
            } else {
                modelContext.insert(
                    PayoffPlan(
                        planId: row.planId,
                        kind: PayoffPlanKind(rawValue: row.kindRaw) ?? .custom,
                        name: row.name,
                        accountId: row.accountId,
                        paymentMethod: row.paymentMethod,
                        originalAmount: row.originalAmount,
                        remainingAmount: row.remainingAmount,
                        monthlyPayment: row.monthlyPayment,
                        monthlyFee: row.monthlyFee,
                        aprPercent: row.aprPercent,
                        startDate: row.startDate,
                        endDate: row.endDate,
                        termMonths: row.termMonths,
                        linkedTransactionId: row.linkedTransactionId,
                        notes: row.notes,
                        isEnded: row.isEnded,
                        lastAppliedStatementDate: row.lastAppliedStatementDate,
                        createdAt: row.createdAt,
                        updatedAt: row.updatedAt
                    )
                )
            }
            count += 1
        }
        return count
    }

    static func mergeCardLabels(_ labels: [String: String]) {
        let existing = CardLabelStore.debugExportMap()
        for (key, value) in labels {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Never clobber a nickname the user already set on this device.
            if let live = existing[key], !live.isEmpty { continue }
            if key.hasPrefix("account:") {
                let id = String(key.dropFirst("account:".count))
                CardLabelStore.setLabel(trimmed, accountId: id)
            } else if key.hasPrefix("method:") {
                let method = String(key.dropFirst("method:".count))
                CardLabelStore.setLabel(trimmed, paymentMethod: method)
            }
        }
    }

    static func mergeVendorRules(_ rules: [VendorRule]) {
        var map = VendorRulesStore.load()
        for rule in rules {
            if let idx = map.firstIndex(where: {
                $0.vendorKey == rule.vendorKey && $0.paymentMethodKey == rule.paymentMethodKey
            }) {
                // Keep local rule (user may have re-trained).
                _ = idx
            } else {
                map.append(rule)
            }
        }
        VendorRulesStore.save(map)
    }
}

// MARK: - Snapshot builders

private extension PlaidConnectionBackup {
    static func snapshot(transaction t: Transaction) -> TransactionSnapshot {
        TransactionSnapshot(
            transactionId: t.transactionId,
            title: t.title,
            amount: t.amount,
            date: t.date,
            category: t.category,
            paymentMethod: t.paymentMethod,
            categoryLocked: t.categoryLocked,
            overrideSource: t.overrideSource,
            plaidPaymentChannel: t.plaidPaymentChannel,
            paymentRail: t.paymentRail,
            paymentRailLocked: t.paymentRailLocked,
            subscriptionCadenceOverride: t.subscriptionCadenceOverride,
            authorizedDate: t.authorizedDate,
            pendingTransactionId: t.pendingTransactionId,
            plaidAccountId: t.plaidAccountId,
            merchantEntityId: t.merchantEntityId,
            merchantName: t.merchantName,
            logoURL: t.logoURL,
            website: t.website,
            pfcConfidence: t.pfcConfidence,
            isPending: t.isPending
        )
    }

    static func snapshot(income i: Income) -> IncomeSnapshot {
        IncomeSnapshot(
            transactionId: i.transactionId,
            source: i.source,
            amount: i.amount,
            date: i.date,
            category: i.category,
            accountName: i.accountName,
            accountMask: i.accountMask,
            sourceInstitution: i.sourceInstitution,
            rawName: i.rawName,
            pfc: i.pfc,
            pending: i.pending,
            kind: i.kind,
            updatedAt: i.updatedAt
        )
    }

    static func snapshot(account a: BankAccount) -> BankAccountSnapshot {
        BankAccountSnapshot(
            accountId: a.accountId,
            itemId: a.itemId,
            name: a.name,
            officialName: a.officialName,
            mask: a.mask,
            type: a.type,
            subtype: a.subtype,
            institutionName: a.institutionName,
            currentBalance: a.currentBalance,
            availableBalance: a.availableBalance,
            creditLimit: a.creditLimit,
            institutionId: a.institutionId,
            lastSyncedAt: a.lastSyncedAt,
            isOverdue: a.isOverdue,
            lastPaymentAmount: a.lastPaymentAmount,
            lastPaymentDate: a.lastPaymentDate,
            lastStatementIssueDate: a.lastStatementIssueDate,
            lastStatementBalance: a.lastStatementBalance,
            minimumPaymentAmount: a.minimumPaymentAmount,
            nextPaymentDueDate: a.nextPaymentDueDate,
            purchaseApr: a.purchaseApr,
            cashApr: a.cashApr,
            balanceTransferApr: a.balanceTransferApr,
            specialApr: a.specialApr,
            liabilitiesSyncedAt: a.liabilitiesSyncedAt
        )
    }

    static func snapshot(payment p: CreditCardPayment) -> PaymentSnapshot {
        PaymentSnapshot(
            transactionId: p.transactionId,
            amount: p.amount,
            date: p.date,
            cardName: p.cardName,
            sourceAccount: p.sourceAccount,
            title: p.title,
            creditAccountId: p.creditAccountId,
            institutionName: p.institutionName
        )
    }

    static func snapshot(stream s: RecurringStream) -> RecurringStreamSnapshot {
        RecurringStreamSnapshot(
            streamId: s.streamId,
            itemId: s.itemId,
            direction: s.direction,
            streamDescription: s.streamDescription,
            merchantName: s.merchantName,
            averageAmount: s.averageAmount,
            lastAmount: s.lastAmount,
            frequency: s.frequency,
            firstDate: s.firstDate,
            lastDate: s.lastDate,
            isActive: s.isActive,
            transactionIds: s.transactionIds,
            accountId: s.accountId,
            updatedAt: s.updatedAt
        )
    }

    static func snapshot(plan p: BudgetPlan) -> BudgetPlanSnapshot {
        BudgetPlanSnapshot(
            planId: p.planId,
            monthlyLimit: p.monthlyLimit,
            categoryLimits: p.categoryLimits,
            expectedIncome: p.expectedIncomeStreams,
            updatedAt: p.updatedAt
        )
    }

    static func snapshot(payoff p: PayoffPlan) -> PayoffPlanSnapshot {
        PayoffPlanSnapshot(
            planId: p.planId,
            kindRaw: p.kindRaw,
            name: p.name,
            accountId: p.accountId,
            paymentMethod: p.paymentMethod,
            originalAmount: p.originalAmount,
            remainingAmount: p.remainingAmount,
            monthlyPayment: p.monthlyPayment,
            monthlyFee: p.monthlyFee,
            aprPercent: p.aprPercent,
            startDate: p.startDate,
            endDate: p.endDate,
            termMonths: p.termMonths,
            linkedTransactionId: p.linkedTransactionId,
            notes: p.notes,
            isEnded: p.isEnded,
            lastAppliedStatementDate: p.lastAppliedStatementDate,
            createdAt: p.createdAt,
            updatedAt: p.updatedAt
        )
    }
}

// MARK: - Auto-included UserDefaults (prefix-based)

/// Captures/restores every UserDefaults key under app prefixes so new prefs
/// ride along in backups without editing Payload fields.
private enum AppPreferenceBackup {
    static let prefixes = ["plaid.", "card.", "settings."]

    static func isAppKey(_ key: String) -> Bool {
        prefixes.contains { key.hasPrefix($0) }
    }

    static func capture() -> [String: Data] {
        var out: [String: Data] = [:]
        let dict = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in dict where isAppKey(key) {
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            ) else { continue }
            out[key] = data
        }
        return out
    }

    static func wipe() {
        let defaults = UserDefaults.standard
        for (key, _) in defaults.dictionaryRepresentation() where isAppKey(key) {
            defaults.removeObject(forKey: key)
        }
    }

    static func restore(_ blob: [String: Data]) {
        for (key, data) in blob {
            guard isAppKey(key),
                  let value = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) else { continue }
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

// MARK: - Envelope crypto (format v1)

extension PlaidConnectionBackup {
    /// On-disk JSON wrapper around hybrid-encrypted payload bytes.
    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: String
        var cipher: String
        /// AES-GCM seal of the random DEK under the password-derived KEK.
        var wrapNonce: String
        var wrapCiphertext: String
        var wrapTag: String
        /// AES-GCM of the payload under the DEK.
        var nonce: String
        var ciphertext: String
        var tag: String
        var createdAt: Date
    }

    // MARK: Encrypt

    fileprivate static func encrypt(payload: Payload, password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(payload)

        let salt = try randomBytes(saltByteCount)
        let dekData = try randomBytes(keyByteCount)
        let dek = SymmetricKey(data: dekData)

        // Password → expensive KDF → domain-separated wrap key (never use password bits raw).
        let kek = try deriveWrapKey(
            password: password,
            salt: salt,
            iterations: pbkdf2Iterations
        )

        let wrappedDEK = try AES.GCM.seal(dekData, using: kek)
        let sealedPayload = try AES.GCM.seal(plaintext, using: dek)

        let envelope = Envelope(
            format: formatID,
            version: formatVersion,
            kdf: kdfID,
            iterations: Int(pbkdf2Iterations),
            salt: salt.base64EncodedString(),
            cipher: cipherID,
            wrapNonce: Data(sealedNonce: wrappedDEK.nonce).base64EncodedString(),
            wrapCiphertext: wrappedDEK.ciphertext.base64EncodedString(),
            wrapTag: wrappedDEK.tag.base64EncodedString(),
            nonce: Data(sealedNonce: sealedPayload.nonce).base64EncodedString(),
            ciphertext: sealedPayload.ciphertext.base64EncodedString(),
            tag: sealedPayload.tag.base64EncodedString(),
            createdAt: payload.createdAt
        )
        let out = JSONEncoder()
        out.dateEncodingStrategy = .iso8601
        out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(envelope)
    }

    // MARK: Decrypt

    fileprivate static func decrypt(envelopeData: Data, password: String) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: envelopeData)
        } catch {
            throw BackupError.invalidFile
        }

        guard envelope.format == formatID else {
            throw BackupError.invalidFile
        }
        guard envelope.version == formatVersion else {
            throw BackupError.unsupportedVersion(envelope.version)
        }
        guard envelope.kdf == kdfID else {
            throw BackupError.unsupportedKDF(envelope.kdf)
        }
        guard envelope.cipher == cipherID else {
            throw BackupError.unsupportedKDF(envelope.cipher)
        }

        guard let salt = Data(base64Encoded: envelope.salt),
              let wrapNonceData = Data(base64Encoded: envelope.wrapNonce),
              let wrapCT = Data(base64Encoded: envelope.wrapCiphertext),
              let wrapTag = Data(base64Encoded: envelope.wrapTag),
              let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else {
            throw BackupError.invalidFile
        }

        let iterations = UInt32(max(1, envelope.iterations))
        let kek = try deriveWrapKey(password: password, salt: salt, iterations: iterations)

        let dekData: Data
        do {
            dekData = try openGCM(
                nonceData: wrapNonceData,
                ciphertext: wrapCT,
                tag: wrapTag,
                key: kek
            )
        } catch {
            throw BackupError.wrongPassword
        }
        guard dekData.count == keyByteCount else {
            throw BackupError.invalidFile
        }

        let plaintext: Data
        do {
            plaintext = try openGCM(
                nonceData: nonceData,
                ciphertext: ciphertext,
                tag: tag,
                key: SymmetricKey(data: dekData)
            )
        } catch {
            throw BackupError.invalidFile
        }

        do {
            return try decoder.decode(Payload.self, from: plaintext)
        } catch {
            throw BackupError.invalidFile
        }
    }

    // MARK: Key derivation

    /// Password → PBKDF2-HMAC-SHA512 → HKDF-SHA512 → 256-bit AES wrap key.
    fileprivate static func deriveWrapKey(
        password: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        let stretched = try pbkdf2(
            password: password,
            salt: salt,
            iterations: iterations,
            derivedKeyLength: keyByteCount
        )
        // Domain separation so the wrap key is not raw PBKDF2 output.
        return HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: stretched),
            salt: salt,
            info: Data("financewizard.backup.v1.kek".utf8),
            outputByteCount: keyByteCount
        )
    }

    fileprivate static func pbkdf2(
        password: String,
        salt: Data,
        iterations: UInt32,
        derivedKeyLength: Int
    ) throws -> Data {
        var derived = Data(count: derivedKeyLength)
        let result: Int32 = password.withCString { passwordPtr in
            salt.withUnsafeBytes { saltBuf in
                derived.withUnsafeMutableBytes { derivedBuf in
                    guard let saltPtr = saltBuf.bindMemory(to: UInt8.self).baseAddress,
                          let outPtr = derivedBuf.bindMemory(to: UInt8.self).baseAddress else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        password.utf8.count,
                        saltPtr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        iterations,
                        outPtr,
                        derivedKeyLength
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw BackupError.cryptoFailed("Key derivation failed (\(result))")
        }
        return derived
    }

    /// Copy an incoming document URL into a stable temp file (Files / cloud “Open in”).
    static func materializeIncomingFile(_ url: URL) throws -> URL {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let name = url.lastPathComponent.isEmpty
            ? "restore.\(fileExtension)"
            : url.lastPathComponent
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString)-\(name)")
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: AES-GCM helpers

    fileprivate static func openGCM(
        nonceData: Data,
        ciphertext: Data,
        tag: Data,
        key: SymmetricKey
    ) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    fileprivate static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BackupError.cryptoFailed("Could not generate secure random bytes")
        }
        return data
    }
}

/// AES.GCM.Nonce → Data without relying on Sequence bridging quirks.
private extension Data {
    init(sealedNonce: AES.GCM.Nonce) {
        self = sealedNonce.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Errors

extension PlaidConnectionBackup {
    enum BackupError: LocalizedError {
        case nothingToBackup
        case emptyPayload
        case passwordTooShort(minimum: Int)
        case wrongPassword
        case invalidFile
        case unsupportedVersion(Int)
        case unsupportedKDF(String)
        case cryptoFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToBackup:
                return "Nothing to back up yet."
            case .emptyPayload:
                return "Backup decrypted but contained nothing usable."
            case .passwordTooShort(let minimum):
                return "Password must be at least \(minimum) characters."
            case .wrongPassword:
                return "Wrong password, or the file is corrupted."
            case .invalidFile:
                return "Not a valid Finance Wizard backup file."
            case .unsupportedVersion(let v):
                return "Unsupported backup version (\(v)). Update the app and try again."
            case .unsupportedKDF(let kdf):
                return "Unsupported encryption method (\(kdf))."
            case .cryptoFailed(let detail):
                return "Encryption error: \(detail)"
            }
        }
    }
}
