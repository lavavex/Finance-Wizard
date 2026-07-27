//
//  DebugDataExport.swift
//  Finance Wizard
//
//  Packages local app data for debugging (shareable backup).
//  Never includes Plaid secrets or access tokens.
//

import Foundation
import SwiftData
import UIKit
import SwiftUI

enum DebugDataExportError: LocalizedError {
    case noAppGroup
    case writeFailed(String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noAppGroup:
            return "App Group container is not available."
        case .writeFailed(let detail):
            return "Could not write export: \(detail)"
        case .encodeFailed:
            return "Could not encode export JSON."
        }
    }
}

/// Builds a temporary folder with JSON snapshot + optional SwiftData store files.
enum DebugDataExporter {
    /// Create export package; caller presents share sheet then should keep URL alive until dismiss.
    @MainActor
    static func exportPackage(modelContext: ModelContext) throws -> URL {
        let stamp = Self.timestamp()
        let folderName = "FinanceWizard-debug-\(stamp)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)

        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 1) Human/AI-readable JSON (primary artifact)
        let snapshot = try buildSnapshot(modelContext: modelContext)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)
        try jsonData.write(to: root.appendingPathComponent("debug-snapshot.json"), options: .atomic)

        // Compact single-file twin (easy to attach in chat)
        try jsonData.write(
            to: root.appendingPathComponent("FinanceWizard-debug-\(stamp).json"),
            options: .atomic
        )

        // 2) README
        let readme = """
        Finance Wizard — debug data export
        ==================================
        Created: \(stamp)
        App: \(AppBuildInfo.displayName) \(AppBuildInfo.versionBuildLabel)
        Bundle: \(AppBuildInfo.bundleIdentifier)

        Contents
        --------
        • debug-snapshot.json / FinanceWizard-debug-*.json
            Full readable dump of SwiftData rows + non-secret preferences.
            Safe to share for debugging. Does NOT include Plaid client_secret
            or access tokens.

        • store/ (if present)
            Raw SwiftData / SQLite files from the App Group container.

        Privacy
        -------
        This file contains your real transaction titles, amounts, account masks,
        and institution names. Only share with someone you trust (or strip fields first).

        Secrets intentionally omitted
        ----------------------------
        • Plaid client_id / secret (Keychain)
        • Plaid access tokens (Keychain)
        """
        try readme.write(
            to: root.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        // 3) Copy store files if present
        try copyStoreFiles(into: root.appendingPathComponent("store", isDirectory: true))

        // 4) Prefer a single zip when possible (easier to AirDrop / attach)
        if let zipURL = try? zipDirectory(root, preferredName: folderName + ".zip") {
            return zipURL
        }
        return root
    }

    // MARK: - Snapshot

    private struct Snapshot: Encodable {
        var meta: Meta
        var counts: Counts
        var bankAccounts: [AccountDTO]
        var transactions: [TransactionDTO]
        var income: [IncomeDTO]
        var creditCardPayments: [PaymentDTO]
        var linkedItems: [LinkedItemDTO]
        var cardLabels: [String: String]
        var vendorRules: [VendorRule]
        var logoCache: [String: Bool]
        var notes: [String]
    }

    private struct Meta: Encodable {
        var exportedAt: String
        var appVersion: String
        var build: String
        var bundleId: String
        var plaidEnvironment: String
        var credentialsConfigured: Bool
        var appGroupID: String
        var schema: [String]
    }

    private struct Counts: Encodable {
        var bankAccounts: Int
        var transactions: Int
        var income: Int
        var creditCardPayments: Int
        var linkedItems: Int
        var vendorRules: Int
        var cardLabels: Int
    }

    private struct AccountDTO: Encodable {
        var accountId: String
        var itemId: String
        var name: String
        var officialName: String?
        var mask: String?
        var type: String
        var subtype: String?
        var institutionName: String
        var institutionId: String?
        var currentBalance: Double
        var availableBalance: Double?
        var creditLimit: Double?
        var lastSyncedAt: String?
        // Liabilities
        var isOverdue: Bool?
        var lastPaymentAmount: Double?
        var lastPaymentDate: String?
        var lastStatementIssueDate: String?
        var lastStatementBalance: Double?
        var minimumPaymentAmount: Double?
        var nextPaymentDueDate: String?
        var purchaseApr: Double?
        var cashApr: Double?
        var balanceTransferApr: Double?
        var specialApr: Double?
        var liabilitiesSyncedAt: String?
        var debitRewardMultiplier: Double?
        var achRewardMultiplier: Double?
        var displayName: String
    }

    private struct TransactionDTO: Encodable {
        var transactionId: String
        var title: String
        var amount: Double
        var date: String
        var category: String
        var paymentMethod: String
        var multiplier: Double
        var categoryLocked: Bool?
        var multiplierLocked: Bool?
        var overrideSource: String?
        var plaidPaymentChannel: String?
        var paymentRail: String?
        var paymentRailLocked: Bool?
        var effectivePaymentRail: String
    }

    private struct IncomeDTO: Encodable {
        var transactionId: String
        var source: String
        var amount: Double
        var date: String
        var category: String
        var accountName: String?
        var accountMask: String?
        var sourceInstitution: String?
        var rawName: String?
        var pfc: String?
        var pending: Bool
        var kind: String
    }

    private struct PaymentDTO: Encodable {
        var transactionId: String
        var amount: Double
        var date: String
        var cardName: String
        var sourceAccount: String?
        var title: String
        var creditAccountId: String?
        var institutionName: String?
    }

    private struct LinkedItemDTO: Encodable {
        var itemId: String
        var institutionName: String
        var accountNames: [String]
        var transactionsCursorPresent: Bool
        var transactionsCursorLength: Int
        var linkedAt: String
        var accessTokenPresent: Bool
        // Never export token value
    }

    @MainActor
    private static func buildSnapshot(modelContext: ModelContext) throws -> Snapshot {
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        let txs = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let income = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        let payments = (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? []
        let items = PlaidItemStore.loadItems()
        let labels = CardLabelStore.debugExportMap()
        let rules = VendorRulesStore.load()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func d(_ date: Date?) -> String? {
            guard let date else { return nil }
            return iso.string(from: date)
        }
        func dReq(_ date: Date) -> String { iso.string(from: date) }

        var notes: [String] = []
        notes.append("Secrets redacted: Plaid client_id/secret and access tokens are not exported.")
        if items.isEmpty {
            notes.append("No linked Plaid Items in metadata.")
        }
        // Lightweight inconsistency hints (helpful for debugging without full analysis)
        let creditIDs = Set(accounts.filter(\.isCredit).map(\.accountId))
        let orphanPayments = payments.filter { pay in
            guard let id = pay.creditAccountId else { return false }
            return !creditIDs.contains(id)
        }
        if !orphanPayments.isEmpty {
            notes.append("\(orphanPayments.count) credit payment(s) reference a creditAccountId not in BankAccount.")
        }
        let unlockedRails = txs.filter { ($0.paymentRail == nil || $0.paymentRail?.isEmpty == true) }
        if !unlockedRails.isEmpty {
            notes.append("\(unlockedRails.count) transaction(s) have no stored paymentRail (will use inference).")
        }
        let noLiabilities = accounts.filter(\.isCredit).filter { $0.liabilitiesSyncedAt == nil }
        if !noLiabilities.isEmpty {
            notes.append("\(noLiabilities.count) credit account(s) have no Liabilities fields (APR/due date). Re-link or enable Liabilities.")
        }
        let missingInstId = accounts.filter { ($0.institutionId ?? "").isEmpty }
        if !missingInstId.isEmpty {
            notes.append("\(missingInstId.count) account(s) missing institutionId (logos won’t resolve by id).")
        }
        let logoStatus = InstitutionLogoCache.debugLogoStatus()
        if logoStatus.isEmpty {
            notes.append("No institution logos cached on disk — Sync to refresh branding.")
        }

        let accountDTOs = accounts
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { a in
                AccountDTO(
                    accountId: a.accountId,
                    itemId: a.itemId,
                    name: a.name,
                    officialName: a.officialName,
                    mask: a.mask,
                    type: a.type,
                    subtype: a.subtype,
                    institutionName: a.institutionName,
                    institutionId: a.institutionId,
                    currentBalance: a.currentBalance,
                    availableBalance: a.availableBalance,
                    creditLimit: a.creditLimit,
                    lastSyncedAt: d(a.lastSyncedAt),
                    isOverdue: a.isOverdue,
                    lastPaymentAmount: a.lastPaymentAmount,
                    lastPaymentDate: d(a.lastPaymentDate),
                    lastStatementIssueDate: d(a.lastStatementIssueDate),
                    lastStatementBalance: a.lastStatementBalance,
                    minimumPaymentAmount: a.minimumPaymentAmount,
                    nextPaymentDueDate: d(a.nextPaymentDueDate),
                    purchaseApr: a.purchaseApr,
                    cashApr: a.cashApr,
                    balanceTransferApr: a.balanceTransferApr,
                    specialApr: a.specialApr,
                    liabilitiesSyncedAt: d(a.liabilitiesSyncedAt),
                    debitRewardMultiplier: a.debitRewardMultiplier,
                    achRewardMultiplier: a.achRewardMultiplier,
                    displayName: a.displayName
                )
            }

        let txDTOs = txs
            .sorted { $0.date > $1.date }
            .map { t in
                TransactionDTO(
                    transactionId: t.transactionId,
                    title: t.title,
                    amount: t.amount,
                    date: dReq(t.date),
                    category: t.category,
                    paymentMethod: t.paymentMethod,
                    multiplier: t.multiplier,
                    categoryLocked: t.categoryLocked,
                    multiplierLocked: t.multiplierLocked,
                    overrideSource: t.overrideSource,
                    plaidPaymentChannel: t.plaidPaymentChannel,
                    paymentRail: t.paymentRail,
                    paymentRailLocked: t.paymentRailLocked,
                    effectivePaymentRail: t.effectivePaymentRail.rawValue
                )
            }

        let incomeDTOs = income
            .sorted { $0.date > $1.date }
            .map { i in
                IncomeDTO(
                    transactionId: i.transactionId,
                    source: i.source,
                    amount: i.amount,
                    date: dReq(i.date),
                    category: i.category,
                    accountName: i.accountName,
                    accountMask: i.accountMask,
                    sourceInstitution: i.sourceInstitution,
                    rawName: i.rawName,
                    pfc: i.pfc,
                    pending: i.pending,
                    kind: i.kind
                )
            }

        let paymentDTOs = payments
            .sorted { $0.date > $1.date }
            .map { p in
                PaymentDTO(
                    transactionId: p.transactionId,
                    amount: p.amount,
                    date: dReq(p.date),
                    cardName: p.cardName,
                    sourceAccount: p.sourceAccount,
                    title: p.title,
                    creditAccountId: p.creditAccountId,
                    institutionName: p.institutionName
                )
            }

        let linkedDTOs = items.map { item in
            LinkedItemDTO(
                itemId: item.id,
                institutionName: item.institutionName,
                accountNames: item.accountNames,
                transactionsCursorPresent: !item.transactionsCursor.isEmpty,
                transactionsCursorLength: item.transactionsCursor.count,
                linkedAt: dReq(item.linkedAt),
                accessTokenPresent: !item.accessToken.isEmpty
            )
        }

        return Snapshot(
            meta: Meta(
                exportedAt: stamp(),
                appVersion: AppBuildInfo.marketingVersion,
                build: AppBuildInfo.buildNumber,
                bundleId: AppBuildInfo.bundleIdentifier,
                plaidEnvironment: PlaidCredentialsStore.environment.rawValue,
                credentialsConfigured: PlaidCredentialsStore.isConfigured,
                appGroupID: SharedStore.appGroupID,
                schema: ["Transaction", "Income", "BankAccount", "CreditCardPayment"]
            ),
            counts: Counts(
                bankAccounts: accounts.count,
                transactions: txs.count,
                income: income.count,
                creditCardPayments: payments.count,
                linkedItems: items.count,
                vendorRules: rules.count,
                cardLabels: labels.count
            ),
            bankAccounts: accountDTOs,
            transactions: txDTOs,
            income: incomeDTOs,
            creditCardPayments: paymentDTOs,
            linkedItems: linkedDTOs,
            cardLabels: labels,
            vendorRules: rules,
            logoCache: InstitutionLogoCache.debugLogoStatus(),
            notes: notes
        )
    }

    // MARK: - Store files

    private static func copyStoreFiles(into storeDir: URL) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else {
            return
        }

        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let support = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        var copied = 0
        if let files = try? FileManager.default.contentsOfDirectory(
            at: support,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.lastPathComponent.hasPrefix(SharedStore.storeName) {
                let dest = storeDir.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.copyItem(at: file, to: dest)
                copied += 1
            }
        }

        // Inventory note
        let inventory = """
        App Group: \(SharedStore.appGroupID)
        Support path: \(support.path)
        Store name prefix: \(SharedStore.storeName)
        Files copied: \(copied)
        """
        try inventory.write(
            to: storeDir.appendingPathComponent("inventory.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Zip (minimal local ZIP writer for share convenience)

    /// Creates a stored-method (no compression) ZIP of all files under `directory`.
    private static func zipDirectory(_ directory: URL, preferredName: String) throws -> URL {
        let zipURL = directory.deletingLastPathComponent().appendingPathComponent(preferredName)
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }

        var entries: [(name: String, data: Data)] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DebugDataExportError.writeFailed("Could not enumerate export folder.")
        }

        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            let relative = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            entries.append((relative, data))
        }

        let zipData = try MinimalZip.pack(entries: entries)
        try zipData.write(to: zipURL, options: .atomic)
        return zipURL
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func stamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - Minimal ZIP (store only)

/// Tiny ZIP writer (method 0 / store) so exports are a single shareable file on iOS.
private enum MinimalZip {
    static func pack(entries: [(name: String, data: Data)]) throws -> Data {
        var localFiles = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            // Local file header
            var local = Data()
            local.append(contentsOf: u32(0x04034b50)) // signature
            local.append(contentsOf: u16(20)) // version needed
            local.append(contentsOf: u16(0)) // flags
            local.append(contentsOf: u16(0)) // method = store
            local.append(contentsOf: u16(0)) // time
            local.append(contentsOf: u16(0)) // date
            local.append(contentsOf: u32(crc))
            local.append(contentsOf: u32(size))
            local.append(contentsOf: u32(size))
            local.append(contentsOf: u16(UInt16(nameData.count)))
            local.append(contentsOf: u16(0)) // extra len
            local.append(nameData)
            local.append(entry.data)

            // Central directory header
            var central = Data()
            central.append(contentsOf: u32(0x02014b50))
            central.append(contentsOf: u16(20)) // version made by
            central.append(contentsOf: u16(20)) // version needed
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(crc))
            central.append(contentsOf: u32(size))
            central.append(contentsOf: u32(size))
            central.append(contentsOf: u16(UInt16(nameData.count)))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(0))
            central.append(contentsOf: u32(offset))
            central.append(nameData)

            localFiles.append(local)
            centralDirectory.append(central)
            offset += UInt32(local.count)
        }

        var end = Data()
        end.append(contentsOf: u32(0x06054b50))
        end.append(contentsOf: u16(0))
        end.append(contentsOf: u16(0))
        end.append(contentsOf: u16(UInt16(entries.count)))
        end.append(contentsOf: u16(UInt16(entries.count)))
        end.append(contentsOf: u32(UInt32(centralDirectory.count)))
        end.append(contentsOf: u32(UInt32(localFiles.count)))
        end.append(contentsOf: u16(0))

        var out = Data()
        out.append(localFiles)
        out.append(centralDirectory)
        out.append(end)
        return out
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [
            UInt8(v & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 24) & 0xff)
        ]
    }

    /// CRC-32 (ISO 3309 / ZIP)
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xedb8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Card labels export helper

extension CardLabelStore {
    /// Full nickname map for debug export (keys like account:… / method:…).
    static func debugExportMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "card.customLabels") as? [String: String] ?? [:]
    }
}
