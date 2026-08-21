//
//  OnboardingStore.swift
//  Finance Wizard
//
//  Remembers whether this device finished first-run onboarding.
//  Key starts with “settings.” so backups already pick it up.
//

import SwiftUI

enum OnboardingStore {
    /// UserDefaults key (`settings.` prefix so encrypted backups include it).
    static let storageKey = "settings.onboardingCompleted"

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}
