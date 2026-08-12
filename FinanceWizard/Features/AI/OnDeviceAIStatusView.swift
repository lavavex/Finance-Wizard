//
//  OnDeviceAIStatusView.swift
//  Finance Wizard
//
//  Tiny Settings-friendly UI to show whether on-device AI is ready.
//  LEARNING SKELETON — fill in the TODOs after availabilityStatus() works.
//

import SwiftUI

/// A small row/section you can later embed in Settings → About (or a new “AI” section).
struct OnDeviceAIStatusView: View {
    // @State: this view owns this value; when it changes, SwiftUI redraws the view.
    @State private var status: OnDeviceAIAvailability = .unavailable(reason: "Not checked yet")

    var body: some View {
        // TODO (after Step 1): show a human-readable label for `status`
        // Ideas:
        // - Text("On-device AI: …")
        // - switch status { case .available: ... case .unavailable(let reason): ... }
        VStack(alignment: .leading, spacing: 8) {
            Text("On-device AI")
                .font(.headline)
            Text(statusLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Check availability") {
                // TODO: Call OnDeviceAI.availabilityStatus() and store it in `status`
                // status = OnDeviceAI.availabilityStatus()
            }
        }
        .padding()
    }

    /// Helper: turn the enum into a string for the UI.
    /// TODO: Improve the wording once you know which cases you use.
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
