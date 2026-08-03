//
//  PlaidItemStore.swift
//  Finance Wizard
//
//  Linked Plaid Items (banks): access tokens in Keychain, metadata + sync cursors in UserDefaults.
//
//  A Plaid “Item” is one bank login connection (may contain multiple accounts).
//  The access_token is secret; everything else (name, cursor, error status) is metadata.
//
//  SWIFT TERMS IN THIS FILE:
//  - struct: Value type (copied when passed around); good for model data.
//  - Codable: Encode/decode JSON for UserDefaults storage.
//  - Identifiable: Has `id` for SwiftUI lists.
//  - Equatable: Can use == and firstIndex(where:).
//  - Sendable: Safe across async boundaries.
//  - compactMap: Map + drop nils (here: skip items with missing Keychain tokens).
//  - filter / map: Transform or keep subsets of arrays.
//  - Key path (\.needsRelink): Short way to refer to a property for filter.
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
    /// A cursor is an opaque string Plaid returns so the next sync only gets deltas.
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
        // Optional binding: only proceed if errorCode is non-nil.
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
/// Split storage design:
/// - Access tokens → Keychain (secure)
/// - Metadata (names, cursors, errors) → UserDefaults as JSON
enum PlaidItemStore {
    private static let metadataKey = "plaid.linkedItems.metadata"
    /// Keychain account prefix; full account = prefix + item_id.
    private static let accessTokenPrefix = "plaid.access."

    /// All linked items with access tokens loaded from Keychain.
    /// Items whose tokens are missing from Keychain are skipped (compactMap → nil).
    static func loadItems() -> [PlaidLinkedItem] {
        // try? turns a throwing decode into an optional (nil on failure).
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let metas = try? JSONDecoder().decode([ItemMeta].self, from: data) else {
            return []
        }
        // compactMap: transform each meta; return nil to drop that element.
        return metas.compactMap { meta in
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

    /// Persist all items: tokens to Keychain, metadata (no tokens) to UserDefaults.
    static func saveItems(_ items: [PlaidLinkedItem]) {
        // Persist tokens in Keychain
        for item in items {
            try? PlaidKeychain.set(item.accessToken, account: accessTokenPrefix + item.id)
        }
        // Metadata without tokens — map each full item to a slim ItemMeta.
        let metas = items.map {
            ItemMeta(
                id: $0.id,
                institutionName: $0.institutionName,
                accountNames: $0.accountNames,
                transactionsCursor: $0.transactionsCursor,
                linkedAt: $0.linkedAt,
                errorCode: $0.errorCode,
                errorMessage: $0.errorMessage,
                lastStatusCheckAt: $0.lastStatusCheckAt
            )
        }
        if let data = try? JSONEncoder().encode(metas) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }

    /// Insert or replace an item by id (upsert = update + insert).
    static func upsert(_ item: PlaidLinkedItem) {
        var items = loadItems()
        // firstIndex(where:) returns the index of the first match, or nil.
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        saveItems(items)
    }

    /// Update only the transactions sync cursor for one Item (after a successful sync page).
    static func updateCursor(itemID: String, cursor: String) {
        var items = loadItems()
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].transactionsCursor = cursor
        saveItems(items)
    }

    /// Record Plaid item error status (or clear it by passing nils via clearItemError).
    static func updateItemStatus(
        itemID: String,
        errorCode: String?,
        errorMessage: String?
    ) {
        var items = loadItems()
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].errorCode = errorCode
        items[idx].errorMessage = errorMessage
        items[idx].lastStatusCheckAt = Date()
        saveItems(items)
    }

    /// Clear stored error after a successful relink or healthy /item/get.
    static func clearItemError(itemID: String) {
        updateItemStatus(itemID: itemID, errorCode: nil, errorMessage: nil)
    }

    /// Empty every item’s cursor so the next sync re-downloads full history.
    static func resetAllCursors() {
        var items = loadItems()
        // items.indices is a Range of valid array indexes (0..<count).
        for i in items.indices {
            items[i].transactionsCursor = ""
        }
        saveItems(items)
    }

    /// Delete Keychain token and metadata for one Item.
    static func remove(itemID: String) {
        PlaidKeychain.delete(account: accessTokenPrefix + itemID)
        // filter keeps only items whose id is NOT the one being removed.
        let items = loadItems().filter { $0.id != itemID }
        // Also drop any orphan metadata if token missing
        saveItems(items)
    }

    /// Convenience: does the user have at least one linked bank?
    static var hasLinkedItems: Bool {
        !loadItems().isEmpty
    }

    /// Items that need Relink (login expired / permission revoked).
    /// `\ .needsRelink` is a key path — shorthand for `{ $0.needsRelink }`.
    static var itemsNeedingRelink: [PlaidLinkedItem] {
        loadItems().filter(\.needsRelink)
    }

    // MARK: - Private metadata (no secrets)

    /// Metadata only (no secret access token).
    /// Private nested struct: only PlaidItemStore can use it.
    private struct ItemMeta: Codable {
        var id: String
        var institutionName: String
        var accountNames: [String]
        var transactionsCursor: String
        var linkedAt: Date
        var errorCode: String?
        var errorMessage: String?
        var lastStatusCheckAt: Date?
    }
}
