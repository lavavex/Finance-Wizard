//
//  AppIntent.swift
//  Widget
//
//  Widget configuration: period (week/month) and cards to hide from the breakdown.
//

import AppIntents
import WidgetKit

// MARK: - Period picker (Week / Month)

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

struct FinanceWizardConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Total Spend" }
    static var description: IntentDescription {
        IntentDescription("Choose week or month. Hide cards from the card list only — Total Spend stays the full period total.")
    }

    @Parameter(title: "Time range", default: .month)
    var period: SpendPeriodOption

    // Hides cards from the per-card breakdown only (not from Total Spend)
    @Parameter(title: "Hide cards", default: [])
    var excludedCards: [PaymentMethodEntity]

    var excludedCardNames: Set<String> {
        Set(excludedCards.map(\.id))
    }
}
