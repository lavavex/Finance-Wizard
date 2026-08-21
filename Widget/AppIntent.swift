//
//  AppIntent.swift
//  Widget
//
//  Edit Widget options: week/month period, and cards to hide from the
//  per-card breakdown (hide-card never shrinks Total Spend).
//

import AppIntents
import WidgetKit

// MARK: - Period picker (Week / Month)

/// Time range options for spend widgets, shown as a system picker.
enum SpendPeriodOption: String, AppEnum {
    case week
    case month

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Time Range")
    }

    static var caseDisplayRepresentations: [SpendPeriodOption: DisplayRepresentation] {
        [
            .week: DisplayRepresentation(title: "This week"),
            .month: DisplayRepresentation(title: "This month")
        ]
    }

    var snapshotPeriod: SnapshotPeriod {
        switch self {
        case .week: return .week
        case .month: return .month
        }
    }
}

// MARK: - Card entity (hide from breakdown only)

/// One payment method / card the user can hide from the per-card list.
struct PaymentMethodEntity: AppEntity {
    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = PaymentMethodQuery()
}

/// Loads card names from SharedStore for the Hide cards multi-select.
struct PaymentMethodQuery: EntityQuery {
    func entities(for identifiers: [PaymentMethodEntity.ID]) async throws -> [PaymentMethodEntity] {
        identifiers.map { PaymentMethodEntity(id: $0, name: $0) }
    }

    func suggestedEntities() async throws -> [PaymentMethodEntity] {
        SharedStore.allPaymentMethods().map { name in
            PaymentMethodEntity(id: name, name: name)
        }
    }
}

// MARK: - Widget configuration intent

/// Edit Widget options for the Total Spend home-screen widget.
struct FinanceWizardConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Total Spend" }
    static var description: IntentDescription {
        IntentDescription("Choose week or month. Hide cards from the card list only — Total Spend stays the full period total.")
    }

    @Parameter(title: "Time range", default: .month)
    var period: SpendPeriodOption

    /// Hide from the per-card breakdown only — Total Spend stays the full period total.
    @Parameter(title: "Hide cards", default: [])
    var excludedCards: [PaymentMethodEntity]

    var excludedCardNames: Set<String> {
        Set(excludedCards.map(\.id))
    }
}
