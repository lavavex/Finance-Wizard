//
//  OnDeviceAIStatusView.swift
//  Finance Wizard
//
//  Settings-friendly row showing whether optional on-device AI is ready.
//

import SwiftUI

/// Small row/section for Settings (About or an AI section).
struct OnDeviceAIStatusView: View {
    @State private var status: OnDeviceAIAvailability = .unavailable(reason: "Not checked yet")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-device AI")
                .font(.headline)
            Text(statusLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Check availability") {
            }
        }
        .padding()
    }

    /// Human-readable label for `status`.
    private var statusLabel: String {
        switch status {
        case .available:
            return "Available"
        case .unavailable(let reason):
            return "Unavailable — \(reason)"
        case .notEnabled(let reason):
            return "Not enabled — \(reason)"
        }
    }
}

#Preview {
    OnDeviceAIStatusView()
}
