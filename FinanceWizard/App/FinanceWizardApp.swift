//
//  FinanceWizardApp.swift
//  Finance Wizard
//
//  App entry point: creates the SwiftData store, starts logo helpers,
//  and shows the root window (splash, then main tabs).
//

// SwiftUI: Apple’s framework for building user interfaces with declarative views.
import SwiftUI
// SwiftData: Apple’s persistence framework (local database of model objects).
import SwiftData

// @main tells Swift this type is the program’s starting point (like main() in other languages).
// struct is a value type: a custom type that holds data and behavior.
// App is a protocol: a contract that says “this type can be the root of a SwiftUI app.”
@main
struct FinanceWizardApp: App {
    // let means immutable after assignment (cannot reassign container later).
    // ModelContainer is the live SwiftData database the whole UI reads/writes through.
    private let container: ModelContainer

    // init() runs once when the app process launches (before any UI appears).
    init() {
        // do/catch: try something that can throw an error; handle failure in catch.
        do {
            // Open the shared App Group store (same on-disk database the widget can use).
            // try marks a call that can throw; if it fails, control jumps to catch.
            container = try SharedStore.makeContainer()
        } catch {
            // fatalError stops the app immediately. Used only when recovery is impossible
            // (e.g. App Group missing, wrong id, or store is corrupted).
            fatalError("Failed to open ModelContainer: \(error)")
        }
        // Start listening for “need a bank logo” notifications (tiles refresh when images arrive).
        InstitutionLogoFetcher.start()
        // Load any logos bundled with the app (e.g. Apple Card screenshot logo).
        InstitutionLogoCache.seedBundledLogos()
    }

    // body is required by App. some Scene means “some concrete scene type”
    // (opaque return type: the compiler knows the exact type; callers only need “a Scene”).
    var body: some Scene {
        // WindowGroup is the main window container on iOS (and multi-window on iPad/macOS).
        WindowGroup {
            // Root view: shows splash once, then ContentView (the tab bar).
            RootWithSplash()
                // Files / iCloud / “Open in Finance Wizard” for .fwbackup documents.
                .onOpenURL { url in
                    handleIncomingBackupURL(url)
                }
        }
        // .modelContainer attaches the database so every child view can use
        // @Query and @Environment(\.modelContext) without passing the store by hand.
        .modelContainer(container)
    }

    /// Materialize a security-scoped document and hand it to Settings restore flow.
    private func handleIncomingBackupURL(_ url: URL) {
        guard PlaidConnectionBackup.isBackupFileURL(url) else { return }
        do {
            let local = try PlaidConnectionBackup.materializeIncomingFile(url)
            AppBackupOpenBridge.pendingURL = local
            AppBackupOpenBridge.pendingError = nil
            NotificationCenter.default.post(
                name: PlaidConnectionBackup.openFileNotification,
                object: local
            )
        } catch {
            AppBackupOpenBridge.pendingURL = nil
            AppBackupOpenBridge.pendingError = error.localizedDescription
            NotificationCenter.default.post(
                name: PlaidConnectionBackup.openFileNotification,
                object: nil
            )
        }
    }
}

/// Hands a file opened from Files / cloud storage to Settings (lazy tab may not exist yet).
enum AppBackupOpenBridge {
    static var pendingURL: URL?
    static var pendingError: String?
}
