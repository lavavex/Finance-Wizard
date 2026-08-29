//
//  OnDeviceAIStatusView.swift
//  Finance Wizard
//

import SwiftUI

struct OnDeviceAIStatusView: View {
    @State private var status: OnDeviceAIAvailability = .unavailable(reason: "Not checked yet")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(statusLabel)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink, .purple, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .onAppear { status = OnDeviceAI.availabilityStatus() }
    }

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
    private var symbolName: String {
        switch status {
        case .available:
            return "apple.intelligence"
        case .unavailable(_), .notEnabled(_):
            return "apple.intelligence.badge.xmark"
            }
        }
    }


#Preview {
    OnDeviceAIStatusView()
}
