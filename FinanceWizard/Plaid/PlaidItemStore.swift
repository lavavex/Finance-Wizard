//
//  PlaidItemStore.swift
//  Finance Wizard
//
//  Linked Plaid Items (banks): access tokens in Keychain, metadata + sync cursors in UserDefaults.
//
//  A Plaid “Item” is one bank login connection (may contain multiple accounts).
//  The access_token is secret; everything else (name, cursor, error status) is metadata.
//

import Foundation

// MARK: - Linked Item model

/// One linked bank / credit card Item from Plaid Link.
///
/// Holds both the secret access token (loaded from Keychain at load time) and
/// non-secret metadata. When saving, tokens go back to Keychain; metadata only
/// to UserDefaults via the private `ItemMeta` type.
struct PlaidLinkedItem: Codable, Identifiable, Equatable, Sendable {
    /// Plaid item_id — unique id for this bank connection.
    var id: String
    /// Secret token used for all subsequent Plaid API calls for this Item.
    var accessToken: String
    /// Bank display name (e.g. "Chase").
    var institutionName: String
    /// Display names for accounts (optional, from Link metadata).
    var accountNames: [String]
    /// Cursor for /transactions/sync (empty = full history from start).
    /// Opaque string Plaid returns so the next sync only gets deltas.
    var transactionsCursor: String
    /// When the user first linked this Item.
    var linkedAt: Date
    /// From `/item/get` — e.g. ITEM_LOGIN_REQUIRED → user should Relink.
    var errorCode: String?
    var errorMessage: String?
    var lastStatusCheckAt: Date?

    /// Payment method label used on local transactions for this Item.
    var paymentMethodLabel: String {
        if institutionName.isEmpty { return "Linked account" }
        return institutionName
    }

    /// True when Plaid says the user must re-authenticate (Relink).
    var needsRelink: Bool {
        guard let code = errorCode?.uppercased() else { return false }
        return code == "ITEM_LOGIN_REQUIRED"
            || code == "ITEM_LOCKED"
            || code == "USER_PERMISSION_REVOKED"
            || code == "PENDING_EXPIRATION"
    }
}

// MARK: - Persistence store

/// Load / save / update linked Plaid Items.
///
/// Split storage:
/// - Access tokens → Keychain (secure)
/// - Metadata (names, cursors, errors) → UserDefaults as JSON
enum PlaidItemStore {
    private static let metadataKey = "plaid.linkedItems.metadata"
    /// Keychain account prefix; full account = prefix + item_id.
    private static let accessTokenPrefix = "plaid.access."

    /// All linked items with access tokens loaded from Keychain.
    /// Items whose tokens are missing from Keychain are skipped.
    static func loadItems() -> [PlaidLinkedItem] {
        loadMetas().compactMap { meta in
            guard let token = PlaidKeychain.get(account: accessTokenPrefix + meta.id), !token.isEmpty else {
                return nil
            }
            return PlaidLinkedItem(
                id: meta.id,
                accessToken: token,
                institutionName: meta.institutionName,
                accountNames: meta.accountNames,
                transactionsCursor: meta.transactionsCursor,
                linkedAt: meta.linkedAt,
                errorCode: meta.errorCode,
                errorMessage: meta.errorMessage,
                lastStatusCheckAt: meta.lastStatusCheckAt
            )
        }
    }

    /// Insert or replace an item by id. The token is written first, so a Keychain failure
    /// throws without recording a bank that has no token.
    static func upsert(_ item: PlaidLinkedItem) throws {
        try PlaidKeychain.set(item.accessToken, account: accessTokenPrefix + item.id)
        var metas = loadMetas()
        let meta = ItemMeta(item)
        if let idx = metas.firstIndex(where: { $0.id == item.id }) {
            metas[idx] = meta
        } else {
            metas.append(meta)
        }
        saveMetas(metas)
    }

    /// Update only the transactions sync cursor for one Item (after a successful sync page).
    static func updateCursor(itemID: String, cursor: String) {
        var metas = loadMetas()
        guard let idx = metas.firstIndex(where: { $0.id == itemID }) else { return }
        metas[idx].transactionsCursor = cursor
        saveMetas(metas)
    }

    /// Record Plaid item error status (or clear it by passing nils via clearItemError).
    static func updateItemStatus(
        itemID: String,
        errorCode: String?,
        errorMessage: String?
    ) {
        var metas = loadMetas()
        guard let idx = metas.firstIndex(where: { $0.id == itemID }) else { return }
        metas[idx].errorCode = errorCode
        metas[idx].errorMessage = errorMessage
        metas[idx].lastStatusCheckAt = Date()
        saveMetas(metas)
    }

    /// Clear stored error after a successful relink or healthy /item/get.
    static func clearItemError(itemID: String) {
        updateItemStatus(itemID: itemID, errorCode: nil, errorMessage: nil)
    }

    /// Empty every item’s cursor so the next sync re-downloads full history.
    static func resetAllCursors() {
        var metas = loadMetas()
        for i in metas.indices {
            metas[i].transactionsCursor = ""
        }
        saveMetas(metas)
    }

    /// Drop every linked Item: Keychain tokens + metadata.
    static func removeAll() {
        PlaidKeychain.deleteAll()
        UserDefaults.standard.removeObject(forKey: metadataKey)
    }

    /// Delete Keychain token and metadata for one Item.
    static func remove(itemID: String) {
        PlaidKeychain.delete(account: accessTokenPrefix + itemID)
        saveMetas(loadMetas().filter { $0.id != itemID })
    }

    /// True when the user has at least one linked bank.
    static var hasLinkedItems: Bool {
        !loadItems().isEmpty
    }

    // MARK: - Private metadata (no secrets)

    /// Metadata only (no secret access token).
    private struct ItemMeta: Codable {
        var id: String
        var institutionName: String
        var accountNames: [String]
        var transactionsCursor: String
        var linkedAt: Date
        var errorCode: String?
        var errorMessage: String?
        var lastStatusCheckAt: Date?

        init(_ item: PlaidLinkedItem) {
            id = item.id
            institutionName = item.institutionName
            accountNames = item.accountNames
            transactionsCursor = item.transactionsCursor
            linkedAt = item.linkedAt
            errorCode = item.errorCode
            errorMessage = item.errorMessage
            lastStatusCheckAt = item.lastStatusCheckAt
        }
    }

    /// Metadata edits skip the Keychain, so an unreadable token can’t drop a bank’s record.
    private static func loadMetas() -> [ItemMeta] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let metas = try? JSONDecoder().decode([ItemMeta].self, from: data) else {
            return []
        }
        return metas
    }

    private static func saveMetas(_ metas: [ItemMeta]) {
        if let data = try? JSONEncoder().encode(metas) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }
}
