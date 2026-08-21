//
//  WidgetBundle.swift
//  Widget
//
//  Widget extension entry point (separate process from the app). Registers
//  Home Screen widgets that read the App Group store.
//

import WidgetKit
import SwiftUI

@main
struct FinanceWizardBundle: WidgetBundle {
    var body: some Widget {
        FinanceHomeWidget()
        CategorySpendWidget()
        BalancesWidget()
    }
}
