//
//  OnboardingGate.swift
//  Finance Wizard
//
//  Root child under splash: Welcome if this device has not finished onboarding,
//  otherwise the tab bar. Get Started only writes the flag; this view swaps the UI.
//  Uses @AppStorage (not OnboardingStore.hasCompleted / raw UserDefaults) so SwiftUI
//  redraws when the flag changes.
//

import SwiftUI

struct OnboardingGate: View {
    @AppStorage(OnboardingStore.storageKey) private var hasCompleted = false
    @Environment(\.sampleData) private var sampleData

    var body: some View {
        if hasCompleted || sampleData.isActive {
            ContentView()
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    OnboardingGate()
}
