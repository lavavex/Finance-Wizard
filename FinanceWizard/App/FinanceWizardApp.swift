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
    /// Replaces `container` while "Try with sample data" is on.
    @State private var sampleContainer: ModelContainer?

    init() {
        PlaidConnectionBackup.purgeTemporaryFiles()
        DebugDataExporter.discardTemporaryFiles()
        do {
            #if DEBUG
            if DemoMode.isEnabled {
                container = try DemoMode.makeSeededContainer()
                return
            }
            #endif
            // Shared App Group store — same on-disk database the widget reads.
            let opened = try SharedStore.makeContainerMovingUnreadableStoreAside()
            container = opened.container
            if opened.movedAside {
                // The new store is empty, so the next Sync has to download full history.
                PlaidItemStore.resetAllCursors()
                AppStoreRecovery.needsNotice = true
            }
        } catch {
            // Unrecoverable: App Group missing, wrong id, or store corrupted.
            fatalError("Failed to open ModelContainer: \(error)")
        }
        InstitutionLogoFetcher.start()
    }

    var body: some Scene {
        WindowGroup {
            RootWithSplash()
                // A new identity, so no screen keeps rows from the other store.
                .id(sampleContainer == nil)
                .modelContainer(sampleContainer ?? container)
                .environment(\.sampleData, SampleDataControl(
                    isActive: sampleContainer != nil,
                    start: startSampleData,
                    exit: exitSampleData
                ))
                // Files / iCloud / “Open in Finance Wizard” for .fwbackup documents.
                .onOpenURL { url in
                    handleIncomingBackupURL(url)
                }
        }
    }

    private func startSampleData() {
        guard let seeded = try? DemoMode.makeSeededContainer() else { return }
        DemoMode.isSampleActive = true
        AskStore.useSampleChat(true)
        sampleContainer = seeded
    }

    private func exitSampleData() {
        DemoMode.isSampleActive = false
        AskStore.useSampleChat(false)
        sampleContainer = nil
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

/// Set at launch when the database couldn’t open and was moved aside.
enum AppStoreRecovery {
    static var needsNotice = false
}

/// Hands a file opened from Files / cloud storage to Settings (lazy tab may not exist yet).
enum AppBackupOpenBridge {
    static var pendingURL: URL?
    static var pendingError: String?
}
