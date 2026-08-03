//
//  WidgetBundle.swift
//  Widget
//
//  Entry point for the widget extension — registers widgets with the system.
//
//  A widget extension is a SEPARATE process from the main app. It has its own
//  @main entry point. iOS launches this target to draw Home Screen widgets.
//
//  SWIFT TERMS IN THIS FILE:
//  - @main: Marks the type that starts this executable target.
//  - WidgetBundle: Groups multiple Widget types so one extension can offer several.
//  - WidgetKit: Apple’s framework for timeline-based home-screen widgets.
//

import WidgetKit
import SwiftUI

// @main marks this as the widget extension starting point (separate from the app).
// Without @main, the extension would not know which type to launch.
@main
struct FinanceWizardBundle: WidgetBundle {
    /// Every widget listed here appears in the iOS widget gallery for this app.
    var body: some Widget {
        // Total Spend by card (list + total)
        FinanceHomeWidget()
        // Spend by category charts (default horizontal bars)
        CategorySpendWidget()
        // Checking & savings balances
        BalancesWidget()
    }
}
