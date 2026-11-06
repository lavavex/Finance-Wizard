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
    /// Which model answered, and how long it took. Nil on questions and older answers.
    var modelName: String?
    var seconds: Double?
    var thread: AskThread?

    init(
        createdAt: Date = .now,
        isUser: Bool,
        text: String,
        modelName: String? = nil,
        seconds: Double? = nil,
        thread: AskThread? = nil
    ) {
        self.createdAt = createdAt
        self.isUser = isUser
        self.text = text
        self.modelName = modelName
        self.seconds = seconds
        self.thread = thread
    }
}

enum AskStore {
    private static let schema = Schema([AskThread.self, AskTurn.self])

    private static let savedChat: ModelContainer = {
        let configuration = ModelConfiguration("AskChat", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Ask chat store failed: \(error)")
        }
    }()

    private static var sampleChat: ModelContainer?

    static var container: ModelContainer { sampleChat ?? savedChat }

    /// Sample questions stay out of the saved chat, and clearing them can't touch it.
    static func useSampleChat(_ on: Bool) {
        let memory = ModelConfiguration("AskChatSample", schema: schema, isStoredInMemoryOnly: true)
        sampleChat = on ? try? ModelContainer(for: schema, configurations: [memory]) : nil
    }

    static func wipe() {
        let context = ModelContext(container)
        try? context.delete(model: AskTurn.self)
        try? context.delete(model: AskThread.self)
        try? context.save()
    }
}
