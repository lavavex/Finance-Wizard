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
struct FinanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Home Screen widget that reads shared SwiftData
        FinanceHomeWidget()
        // Template Control / Live Activity widgets are left out for now
        // (files can stay in the folder; they just are not registered)
    }
}
