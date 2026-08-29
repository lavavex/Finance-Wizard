//
//  AskModels.swift
//  Finance Wizard
//
//  Ask chat persistence in a separate SwiftData store so finance-schema
//  migrations never wipe the ledger.
//

import Foundation
import SwiftData

@Model
final class AskThread {
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \AskTurn.thread)
    var turns: [AskTurn]

    init(updatedAt: Date = .now, turns: [AskTurn] = []) {
        self.updatedAt = updatedAt
        self.turns = turns
    }
}

@Model
final class AskTurn {
    var createdAt: Date
    var isUser: Bool
    var text: String
    var thread: AskThread?

    init(createdAt: Date = .now, isUser: Bool, text: String, thread: AskThread? = nil) {
        self.createdAt = createdAt
        self.isUser = isUser
        self.text = text
        self.thread = thread
    }
}

enum AskStore {
    static let container: ModelContainer = {
        let schema = Schema([AskThread.self, AskTurn.self])
        let configuration = ModelConfiguration("AskChat", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Ask chat store failed: \(error)")
        }
    }()

    static func wipe() {
        let context = ModelContext(container)
        try? context.delete(model: AskTurn.self)
        try? context.delete(model: AskThread.self)
        try? context.save()
    }
}
