//
//  FinanceWizardApp.swift
//  Finance Wizard
//
//  App entry point: SwiftData store, logo helpers, root window
//  (splash → OnboardingGate → Welcome or tabs).
//

import SwiftUI
import SwiftData

@main
struct FinanceWizardApp: App {
    private let container: ModelContainer

    init() {
        do {
            // Shared App Group store — same on-disk database the widget reads.
            container = try SharedStore.makeContainer()
        } catch {
            // Unrecoverable: App Group missing, wrong id, or store corrupted.
            fatalError("Failed to open ModelContainer: \(error)")
        }
        InstitutionLogoFetcher.start()
    }

    var body: some Scene {
        WindowGroup {
            RootWithSplash()
                // Files / iCloud / “Open in Finance Wizard” for .fwbackup documents.
                .onOpenURL { url in
                    handleIncomingBackupURL(url)
                }
        }
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
