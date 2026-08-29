//
//  RecurringCalendarView.swift
//  Finance Wizard
//
//  Native month calendar for the Recurring tab (system UICalendarView).
//

import SwiftUI
import UIKit

struct RecurringCalendarView: UIViewRepresentable {

    var chargeDays: Set<DateComponents>
    @Binding var selectedDay: DateComponents?
    func makeUIView(context: Context) -> UICalendarView {
        let grid = UICalendarView()
        grid.calendar = Calendar.current
        grid.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        grid.selectionBehavior = selection
        return grid
    }
    
    func updateUIView(_ uiView: UICalendarView, context: Context) {
        context.coordinator.chargeDays = chargeDays
        uiView.reloadDecorations(forDateComponents: Array(chargeDays), animated: true)
        
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(chargeDays: chargeDays, selectedDay: $selectedDay)

    }
    
    class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var chargeDays: Set<DateComponents>
        var selectedDay: Binding<DateComponents?>
        init(chargeDays: Set<DateComponents>, selectedDay: Binding<DateComponents?>) {
            self.chargeDays = chargeDays
            self.selectedDay = selectedDay
        }
        
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            selectedDay.wrappedValue = dateComponents
        }
        
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            if chargeDays.contains(where: {
                $0.year == dateComponents.year &&
                $0.month == dateComponents.month &&
                $0.day == dateComponents.day
            }) {
                return .default()
                }
            return nil
            
        }
    }
}


#Preview {
    RecurringCalendarView(chargeDays: [Calendar.current.dateComponents([.year, .month, .day], from: Date())], selectedDay: .constant(nil))
}
