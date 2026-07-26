//
//  TransactionDetailView.swift
//  FinanceWidget
//
//  Tap a transaction → view details, edit category / multiplier, push to server.
//

import SwiftUI
import SwiftData
import WidgetKit

// Built-in fallback categories if GET /api/categories is empty/unreachable
enum KnownCategory: String, CaseIterable, Identifiable {
    case dining = "Dining"
    case gas = "Gas (Car)"
    case groceries = "Groceries"
    case subscriptions = "Subscriptions"
    case shopping = "Shopping"
    case travel = "Travel"
    case carInsurance = "Car Insurance"
    case homeInternet = "Home Internet"
    case personalCare = "Personal Care"
    case miscellaneous = "Miscellaneous"

    var id: String { rawValue }

    var systemImage: String {
        CategoryStyle.symbolName(for: rawValue)
    }

    static var defaultNames: [String] {
        allCases.map(\.rawValue)
    }
}

// Detail + edit screen for one SwiftData transaction
struct TransactionDetailView: View {
    // The live model object (edits write through to SwiftData after server accepts)
    @Bindable var transaction: Transaction

    @Environment(\.modelContext) private var modelContext

    // Draft fields
    @State private var categoryText: String = ""
    @State private var multiplierText: String = ""
    // Push options (map to classify API body)
    @State private var learn = true
    @State private var scopePaymentMethod = false
    @State private var applyToMatching = false
    // Categories from server (or fallback)
    @State private var categoryOptions: [String] = KnownCategory.defaultNames
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSave = false
    @State private var saveStatusMessage: String?

    // All local rows — used when applyToMatching updates the same vendor on device
    @Query private var allTransactions: [Transaction]

    private var selectedPreset: String? {
        categoryOptions.first { $0 == categoryText }
    }

    var body: some View {
        Form {
            // Read-only identity / money
            Section {
                HStack(spacing: 12) {
                    Image(systemName: CategoryStyle.symbolName(for: categoryText.isEmpty ? transaction.category : categoryText))
                        .font(.largeTitle)
                        .foregroundStyle(CategoryStyle.color(for: categoryText.isEmpty ? transaction.category : categoryText))
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.title)
                            .font(.title3.weight(.semibold))
                        Text(transaction.amount, format: .currency(code: "USD"))
                            .font(.title2.bold())
                            .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("Date") {
                    Text(transaction.date, style: .date)
                }
                LabeledContent("Card") {
                    HStack(spacing: 8) {
                        BankIconView(paymentMethod: transaction.paymentMethod, size: 24)
                        Text(transaction.paymentMethod)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("ID") {
                    Text(transaction.transactionId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if transaction.isCategoryLocked || transaction.isMultiplierLocked {
                    LabeledContent("Locked on server") {
                        Text(lockSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let source = transaction.overrideSource, !source.isEmpty {
                    LabeledContent("Override source") {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Editable fields
            Section {
                Picker("Category", selection: categoryPickerBinding) {
                    ForEach(categoryOptions, id: \.self) { name in
                        Label(name, systemImage: CategoryStyle.symbolName(for: name))
                            .tag(Optional(name))
                    }
                    Label("Custom…", systemImage: "pencil")
                        .tag(Optional<String>.none)
                }

                TextField("Category name", text: $categoryText)
                    .textInputAutocapitalization(.words)

                HStack {
                    Text("Points multiplier")
                    Spacer()
                    TextField("1", text: $multiplierText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                    Text("x")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Edit")
            } footer: {
                Text("Save pushes to finance-sync and locks this row so later Plaid syncs won’t overwrite it (when learn is on, the vendor rule is remembered too).")
            }

            // Server classify options
            Section {
                Toggle("Remember for this vendor (learn)", isOn: $learn)
                Toggle("Only same card/account", isOn: $scopePaymentMethod)
                Toggle("Apply to other matching transactions", isOn: $applyToMatching)
            } header: {
                Text("Server options")
            } footer: {
                Text("Learn stores a rule for future purchases. Apply to matching also updates other existing rows on the server (and locally when possible).")
            }

            Section("Points (estimate)") {
                let points = abs(transaction.amount) * (Double(multiplierText.replacingOccurrences(of: ",", with: ".")) ?? transaction.multiplier)
                LabeledContent("Points") {
                    Text(points, format: .number.precision(.fractionLength(0...2)))
                }
                LabeledContent("~ Value @ 1¢/pt") {
                    Text(points * 0.01, format: .currency(code: "USD"))
                }
            }

            if didSave {
                Section {
                    Label(saveStatusMessage ?? "Saved to device and server", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task { await saveEdits() }
                    }
                }
            }
        }
        .alert("Couldn’t save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear {
            categoryText = transaction.category
            multiplierText = formatMultiplier(transaction.multiplier)
        }
        .task {
            // Prefer live category list from the portal
            let remote = await FinanceSyncAPI.fetchCategories()
            if !remote.isEmpty {
                // Merge server list with current value so custom categories still appear
                var merged = remote
                if !merged.contains(transaction.category), !transaction.category.isEmpty {
                    merged.insert(transaction.category, at: 0)
                }
                categoryOptions = merged
            }
        }
    }

    private var lockSummary: String {
        var parts: [String] = []
        if transaction.isCategoryLocked { parts.append("category") }
        if transaction.isMultiplierLocked { parts.append("multiplier") }
        return parts.joined(separator: " + ")
    }

    private var categoryPickerBinding: Binding<String?> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                if let newValue {
                    categoryText = newValue
                }
            }
        )
    }

    private func formatMultiplier(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return value.formatted()
    }

    // Validate → POST classify → update local SwiftData (+ optional matching rows)
    @MainActor
    private func saveEdits() async {
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategory.isEmpty else {
            saveError = "Category can’t be empty."
            return
        }

        let normalized = multiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let multiplier = Double(normalized), multiplier >= 0 else {
            saveError = "Multiplier must be a number 0 or greater."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            // 1) Push to finance-sync (locks + optional learn / bulk apply on server)
            try await FinanceSyncAPI.classify(
                transactionId: transaction.transactionId,
                category: trimmedCategory,
                multiplier: multiplier,
                learn: learn,
                scopePaymentMethod: scopePaymentMethod,
                applyToMatching: applyToMatching
            )

            // 2) Update this row locally
            transaction.category = trimmedCategory
            transaction.multiplier = multiplier
            transaction.categoryLocked = true
            transaction.multiplierLocked = true
            transaction.overrideSource = "user"

            // 3) Optionally mirror bulk apply on device for same vendor (and card if scoped)
            var localExtra = 0
            if applyToMatching {
                localExtra = applyLocalMatching(
                    category: trimmedCategory,
                    multiplier: multiplier
                )
            }

            try modelContext.save()
            WidgetCenter.shared.reloadAllTimelines()

            if localExtra > 0 {
                saveStatusMessage = "Saved. Updated \(localExtra + 1) local transactions."
            } else {
                saveStatusMessage = "Saved to device and server"
            }
            didSave = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                didSave = false
            }
        } catch {
            // Do not write local-only if server rejected — keeps device/server consistent
            saveError = error.localizedDescription
        }
    }

    // Best-effort local bulk update for matching vendors after server applyToMatching
    @discardableResult
    private func applyLocalMatching(category: String, multiplier: Double) -> Int {
        let vendor = transaction.title
        let card = transaction.paymentMethod
        var count = 0

        for row in allTransactions {
            if row.transactionId == transaction.transactionId { continue }
            // Same merchant name (simple equality; server uses looser matching)
            guard row.title.caseInsensitiveCompare(vendor) == .orderedSame else { continue }
            if scopePaymentMethod,
               row.paymentMethod.caseInsensitiveCompare(card) != .orderedSame {
                continue
            }
            row.category = category
            row.multiplier = multiplier
            row.categoryLocked = true
            row.multiplierLocked = true
            row.overrideSource = "user"
            count += 1
        }
        return count
    }
}

#Preview {
    NavigationStack {
        Text("Open a transaction from the list")
    }
}
