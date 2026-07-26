//
//  TransactionDetailView.swift
//  FinanceWidget
//
//  Tap a transaction → view full details and edit category / multiplier.
//

import SwiftUI
import SwiftData
import WidgetKit

// Known budget categories from finance-sync (plus free-text “Other”)
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

    // SF Symbol for the picker row
    var systemImage: String {
        CategorySymbol.name(forCategory: rawValue)
    }
}

// Detail + edit screen for one SwiftData transaction
struct TransactionDetailView: View {
    // The live model object (edits write through to SwiftData)
    @Bindable var transaction: Transaction

    // Save / discard context
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Draft fields so we can validate before writing
    @State private var categoryText: String = ""
    @State private var multiplierText: String = ""
    @State private var saveError: String?
    @State private var didSave = false

    // Whether the current category matches a known preset
    private var selectedKnownCategory: KnownCategory? {
        KnownCategory.allCases.first { $0.rawValue == categoryText }
    }

    var body: some View {
        Form {
            // Read-only identity / money info
            Section {
                HStack(spacing: 12) {
                    Image(systemName: CategorySymbol.name(forCategory: categoryText.isEmpty ? transaction.category : categoryText))
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
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
            }

            // Editable fields
            Section {
                // Quick pick from known categories
                Picker("Category", selection: categoryPickerBinding) {
                    ForEach(KnownCategory.allCases) { cat in
                        Label(cat.rawValue, systemImage: cat.systemImage)
                            .tag(Optional(cat))
                    }
                    // “Custom” keeps whatever is in the text field
                    Label("Custom…", systemImage: "pencil")
                        .tag(Optional<KnownCategory>.none)
                }

                // Always allow free-text category (sync may invent new ones)
                TextField("Category name", text: $categoryText)
                    .textInputAutocapitalization(.words)

                // Multiplier as text so user can type 1.5, 5, etc.
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
                Text("Changes save to this device (SwiftData). The next Sync from the server may overwrite category/multiplier if the PC export still has the old values.")
            }

            // Estimated points for this txn (expense amounts are negative in storage)
            Section("Points (estimate)") {
                let points = abs(transaction.amount) * (Double(multiplierText) ?? transaction.multiplier)
                LabeledContent("Points") {
                    Text(points, format: .number.precision(.fractionLength(0...2)))
                }
                LabeledContent("~ Value @ 1¢/pt") {
                    Text(points * 0.01, format: .currency(code: "USD"))
                }
            }

            if didSave {
                Section {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveEdits()
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
            // Seed drafts from the model
            categoryText = transaction.category
            multiplierText = formatMultiplier(transaction.multiplier)
        }
    }

    // Picker binding: known category or nil (custom)
    private var categoryPickerBinding: Binding<KnownCategory?> {
        Binding(
            get: { selectedKnownCategory },
            set: { newValue in
                if let newValue {
                    categoryText = newValue.rawValue
                }
                // Choosing “Custom…” leaves categoryText as-is for typing
            }
        )
    }

    private func formatMultiplier(_ value: Double) -> String {
        // Avoid ugly “5.000000”
        if value.rounded() == value {
            return String(Int(value))
        }
        return value.formatted()
    }

    private func saveEdits() {
        // Category: require non-empty
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategory.isEmpty else {
            saveError = "Category can’t be empty."
            return
        }

        // Multiplier: parse number
        let normalized = multiplierText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let multiplier = Double(normalized), multiplier >= 0 else {
            saveError = "Multiplier must be a number 0 or greater."
            return
        }

        transaction.category = trimmedCategory
        transaction.multiplier = multiplier

        do {
            try modelContext.save()
            // Multiplier/category can affect widget points later — refresh timelines
            WidgetCenter.shared.reloadAllTimelines()
            didSave = true
            // Brief confirmation then clear flag
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                didSave = false
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    // Preview needs a model container; empty shell for canvas
    NavigationStack {
        Text("Open a transaction from the list")
    }
}
