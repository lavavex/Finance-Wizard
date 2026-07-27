//
//  WidgetBundle.swift
//  Widget
//
//  Entry point for the widget extension — registers widgets with the system.
//

import WidgetKit
import SwiftUI

// @main marks this as the widget extension starting point (separate from the app)
@main
struct FinanceWizardBundle: WidgetBundle {
    var body: some Widget {
        // Total Spend by card (list + total)
        FinanceHomeWidget()
        // Spend by category charts (default horizontal bars)
        CategorySpendWidget()
        // Template Control / Live Activity widgets are left out for now
    }
}
