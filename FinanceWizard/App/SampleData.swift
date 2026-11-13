//
//  SampleData.swift
//  Finance Wizard
//
//  "Try with sample data": the app runs on an in-memory store of made-up rows, so anyone can
//  look around without Plaid keys, including App Review. It ends when the app closes. Real data
//  isn't opened for reading or writing while it's on.
//

import SwiftData
import SwiftUI

struct SampleDataControl {
    var isActive = false
    var start: () -> Void = {}
    var exit: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var sampleData = SampleDataControl()
}

/// Top of the main screens, so sample numbers are never mistaken for real ones.
struct SampleDataBanner: View {
    @Environment(\.sampleData) private var sampleData

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("You're viewing sample data", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text("These numbers are made up. Nothing you change here is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Exit Sample Data") { sampleData.exit() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        }
    }
}
