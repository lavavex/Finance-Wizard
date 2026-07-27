//
//  PlaidItemStore.swift
//  Finance Wizard
//
//  Linked Plaid Items (banks): access tokens in Keychain, metadata + sync cursors in UserDefaults.
//

import Foundation

/// One linked bank / credit card Item from Plaid Link.
struct PlaidLinkedItem: Codable, Identifiable, Equatable, Sendable {
    /// Plaid item_id
    var id: String
    var accessToken: String
    var institutionName: String
    /// Display names for accounts (optional, from Link metadata)
    var accountNames: [String]
    /// Cursor for /transactions/sync (empty = full history from start)
    var transactionsCursor: String
    var linkedAt: Date

    /// Payment method label used on local transactions for this Item.
    var paymentMethodLabel: String {
        if institutionName.isEmpty { return "Linked account" }
        return institutionName
    }
}

enum PlaidItemStore {
    private static let metadataKey = "plaid.linkedItems.metadata"
    private static let accessTokenPrefix = "plaid.access."

    /// All linked items with access tokens loaded from Keychain.
    static func loadItems() -> [PlaidLinkedItem] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let metas = try? JSONDecoder().decode([ItemMeta].self, from: data) else {
            return []
        }
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
                linkedAt: meta.linkedAt
            )
        }
    }

    static func saveItems(_ items: [PlaidLinkedItem]) {
        // Persist tokens in Keychain
        for item in items {
            try? PlaidKeychain.set(item.accessToken, account: accessTokenPrefix + item.id)
        }
        // Metadata without tokens
        let metas = items.map {
            ItemMeta(
                id: $0.id,
                institutionName: $0.institutionName,
                accountNames: $0.accountNames,
                transactionsCursor: $0.transactionsCursor,
                linkedAt: $0.linkedAt
            )
        }
        if let data = try? JSONEncoder().encode(metas) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }

    static func upsert(_ item: PlaidLinkedItem) {
        var items = loadItems()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        saveItems(items)
    }

    static func updateCursor(itemID: String, cursor: String) {
        var items = loadItems()
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].transactionsCursor = cursor
        saveItems(items)
    }

    static func resetAllCursors() {
        var items = loadItems()
        for i in items.indices {
            items[i].transactionsCursor = ""
        }
        saveItems(items)
    }

    static func remove(itemID: String) {
        PlaidKeychain.delete(account: accessTokenPrefix + itemID)
        var items = loadItems().filter { $0.id != itemID }
        // Also drop any orphan metadata if token missing
        saveItems(items)
    }

    static var hasLinkedItems: Bool {
        !loadItems().isEmpty
    }

    // Metadata only (no secret access token)
    private struct ItemMeta: Codable {
        var id: String
        var institutionName: String
        var accountNames: [String]
        var transactionsCursor: String
        var linkedAt: Date
    }
}
