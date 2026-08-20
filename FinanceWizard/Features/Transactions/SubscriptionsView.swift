//
//  SubscriptionsView.swift
//  Finance Wizard
//
//  Blank starter for tracking subscriptions / recurring transactions.
//

import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    // @Query = every Transaction from the database; refreshes if they change.
    @Query private var transactions: [Transaction]
    
    // @State = this screen owns the value; the UI updates when it changes.
    @State private var candidates: [SubscriptionCandidate] = []
    @State private var ended: [SubscriptionCandidate] = []
    @State private var isScanning = true
    @State private var isSpinning = false
    @State private var workFinished = false
    @State private var workLog: [String] = []
    @State private var workStartedAt: Date?
    @State private var path = NavigationPath()

    @Environment(\.modelContext) private var modelContext
    
    private var totalMonthly: Double {
        candidates.reduce(0) { $0 + $1.estimatedMonthly }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Est. Monthly")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MoneyText(totalMonthly)
                                .font(.title2.weight(.bold))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(isScanning ? "Scanning..." : "\(candidates.count) recurring")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section {
                    if isScanning && candidates.isEmpty {
                        ProgressView("Scanning...")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .listRowBackground(Color.clear)
                    } else if candidates.isEmpty {
                        ContentUnavailableView("No Recurring Charges Found", systemImage: "repeat.circle", description: Text("Recurring Charges will show up here.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(candidates) { item in
                            NavigationLink(value: item.id) {
                                subscriptionRow(item)
                            }
                        }
                    }
                } header: {
                    Text("Active")
                }

                if !ended.isEmpty {
                    Section {
                        ForEach(ended) { item in
                            NavigationLink(value: item.id) {
                                subscriptionRow(item)
                            }
                        }
                    } header: {
                        Text("Ended")
                    }
                }
            }
            // .navigationTitle hangs off List (the `}` above), not as its own line in NavigationStack.
            .navigationTitle("Recurring Charges")
            .navigationDestination(for: String.self) { id in
                if let item = candidates.first(where: { $0.id == id }) {
                    recurringDetail(item, showCancelledButton: true)
                } else if let item = ended.first(where: { $0.id == id }) {
                    recurringDetail(item, showCancelledButton: false)
                }
            }
            .task {
                await rescan()
            }
        }
        .overlay {
            if isSpinning {
                workingOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: isSpinning)
    }
    
    private func recurringDetail(_ item: SubscriptionCandidate, showCancelledButton: Bool) -> some View {
        // Skip the expensive charge scan while the overlay is up so each
        // SwiftData write does not rebuild Times Seen + the charge list.
        let matches = isSpinning ? [] : matchingTransactions(for: item)
        return List {
            LabeledContent("Cadence", value: item.cadence.displayName)
            if !isSpinning {
                LabeledContent("Times Seen", value: "\(matches.count)")
            }
            LabeledContent("Why", value: item.confidenceNote)
            LabeledContent("Last Charged", value: item.lastDate.formatted(date: .abbreviated, time: .omitted))
            if let next = nextChargeDate(for: item), next > Date() {
                LabeledContent("Next Charge", value: next.formatted(date: .abbreviated, time: .omitted))
            }
            Section {
                Button("Not Recurring", role: .destructive) {
                    Task { await markNotRecurring(item) }
                }
                .disabled(isSpinning)
            }
            if showCancelledButton {
                Section {
                    Button("Cancelled", role: .destructive) {
                        Task { await markEnded(item) }
                    }
                    .disabled(isSpinning)
                }
            }
            if !isSpinning {
                Section("Charges") {
                    ForEach(matches) { tx in
                        NavigationLink {
                            TransactionDetailView(transaction: tx)
                        } label: {
                            TransactionRowView(transaction: tx)
                        }
                    }
                }
            }
        }
        .navigationTitle(item.displayVendor)
    }

    @ViewBuilder
    private func subscriptionRow(_ item: SubscriptionCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "repeat.circle.fill")
                .font(.title3)
                .foregroundStyle(item.isUserDeclared ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayVendor)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let next = nextChargeDate(for: item), next > Date() {
                    Text("\(item.cadence.displayName) · next \(next.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(item.cadence.displayName) · last \(item.lastDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer(minLength: 8)
            
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(item.typicalAmount)
                    .font(.body.weight(.semibold))
                MoneyText(item.estimatedMonthly, prefix: "~", suffix: "/mo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var workingOverlay: some View {
        if isSpinning {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Spacer()
                    BundleGIFView(resource: "WorkingOverlay")
                        .frame(width: 240, height: 164)
                    if workFinished {
                        Text("Done!")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                    } else {
                        TimelineView(.periodic(from: .now, by: 0.4)) { context in
                            let dots = (Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3) + 1
                            Text("Working...")
                                .font(.headline.weight(.semibold))
                                .hidden()
                                .overlay {
                                    Text("Working" + String(repeating: ".", count: dots))
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.white)
                                }
                        }
                    }
                    Spacer()
                    workLogPanel
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .allowsHitTesting(true)
        }
    }

    private var workLogPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(workLog.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    // @MainActor = update UI state on the main thread. async = allowed to pause (await).
    @MainActor
    private func detectGroups() async -> (active: [SubscriptionCandidate], ended: [SubscriptionCandidate]) {
        await logWork("Snapshotting \(transactions.count) transactions")
        let snaps = SubscriptionAnalytics.snapshots(from: transactions)
        await logWork("Detecting recurring charges")
        let found = await Task.detached(priority: .userInitiated) {
            SubscriptionAnalytics.detectAll(snapshots: snaps)
        }.value
        await logWork("Detector returned \(found.count) group(s)")
        await logWork("Building cancelled-vendor set")
        let cancelledVendors = Set(
            transactions.compactMap { tx -> String? in
                guard (tx.subscriptionCadenceOverride ?? "").lowercased() == "cancelled" else {
                    return nil
                }
                return SubscriptionAnalytics.normalizeVendor(tx.title)
            }
        )
        await logWork("\(cancelledVendors.count) cancelled vendor(s)")
        let active = found.filter { SubscriptionAnalytics.isActive($0) && !cancelledVendors.contains($0.normalizedVendor) }
        let endedGroups = found.filter { !SubscriptionAnalytics.isActive($0) || cancelledVendors.contains($0.normalizedVendor) }
        await logWork("Active \(active.count), ended \(endedGroups.count)")
        return (active, endedGroups)
    }

    @MainActor
    private func rescan(showScanning: Bool = true) async {
        if showScanning { isScanning = true }
        let groups = await detectGroups()
        candidates = groups.active
        ended = groups.ended
        isScanning = false
    }
    
    private func matchingTransactions(for item: SubscriptionCandidate) -> [Transaction] {
        transactions
            .filter { tx in
                if tx.isDeclaredNotSubscription { return false }
                let vendor = SubscriptionAnalytics.normalizeVendor(tx.title)
                if vendor != item.normalizedVendor { return false }
                let tol = max(0.25, item.typicalAmount * 0.01)
                return abs(abs(tx.amount) - item.typicalAmount) <= tol
            }
            .sorted { $0.date > $1.date }
    }
    
    private func nextChargeDate(for item: SubscriptionCandidate) -> Date? {
        let cal = Calendar.current
        switch item.cadence {
        case .weekly:
            return cal.date(byAdding: .day,  value: 7, to: item.lastDate)
        case .monthly:
            return cal.date(byAdding: .month, value: 1, to: item.lastDate)
        case .yearly:
            return cal.date(byAdding: .year, value: 1, to: item.lastDate)
        }
    }

    @MainActor
    private func markNotRecurring(_ item: SubscriptionCandidate) async {
        await applyOverride("none", on: item)
    }

    @MainActor
    private func markEnded(_ item: SubscriptionCandidate) async {
        await applyOverride("cancelled", on: item)
    }

    @MainActor
    private func applyOverride(_ value: String, on item: SubscriptionCandidate) async {
        workLog = []
        workStartedAt = Date()
        workFinished = false
        isSpinning = true
        defer {
            isSpinning = false
            workFinished = false
        }
        await logWork("Cancelled “\(item.displayVendor)”")
        await logWork("Finding matching charges")
        let matches = matchingTransactions(for: item)
        await logWork("Found \(matches.count) charge(s)")
        await logWork("Writing “\(value)” on each")
        for tx in matches {
            tx.subscriptionCadenceOverride = value
        }
        await logWork("Saving")
        try? modelContext.save()
        await logWork("Saved")
        await logWork("Rescanning")
        let groups = await detectGroups()
        await logWork("Done")
        workFinished = true
        try? await Task.sleep(for: .seconds(2.5))
        path = NavigationPath()
        candidates = groups.active
        ended = groups.ended
        isScanning = false
    }

    @MainActor
    private func logWork(_ message: String) async {
        guard isSpinning else { return }
        let elapsed: String
        if let start = workStartedAt {
            elapsed = String(format: "+%5.2fs", Date().timeIntervalSince(start))
        } else {
            elapsed = "+ 0.00s"
        }
        let line = "\(elapsed)  \(message)"
        workLog.append(line)
        print("[Recurring] \(line)")
    }
}

#Preview {
    SubscriptionsView()
}

