//
//  FinanceWizardApp.swift
//  Finance Wizard
//
//  Created by roberth on 7/26/26.
//

// SwiftUI app entry
import SwiftUI
// SwiftData container attachment
import SwiftData

// @main marks this as the program starting point
@main
struct FinanceWizardApp: App {
    // The live database the whole UI reads/writes through
    private let container: ModelContainer

    // Runs once when the app process launches
    init() {
        do {
            // Open the shared App Group store (same one the widget will use)
            container = try SharedStore.makeContainer()
        } catch {
            // If this crashes: App Group missing, wrong id, or store is corrupted
            fatalError("Failed to open ModelContainer: \(error)")
        }
    }

    // Root scene: one window showing ContentView, with SwiftData injected
    var body: some Scene {
        WindowGroup {
            // Main screen
            ContentView()
        }
        // Every view under this window can use @Query and modelContext
        .modelContainer(container)
    }
}
