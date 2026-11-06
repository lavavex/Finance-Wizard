//
//  DeveloperTools.swift
//  Finance Wizard
//
//  The Debug menu and database export can reveal or erase real data, so App Store builds hide them.
//

import StoreKit

enum DeveloperTools {
    /// App Store and unknown environments stay hidden. TestFlight reports as sandbox.
    static func isAvailable(in environment: AppStore.Environment?) -> Bool {
        environment == .sandbox || environment == .xcode
    }

    static func isAvailable() async -> Bool {
        #if DEBUG
        return true
        #else
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return false }
        return isAvailable(in: transaction.environment)
        #endif
    }
}
