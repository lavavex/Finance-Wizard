//
//  AppIntent.swift
//  Widget
//
//  Widget configuration: period (week/month) and cards to hide from the breakdown.
//
//  App Intents power the long-press “Edit Widget” sheet. When the user picks
//  options, WidgetKit re-asks the TimelineProvider for a new timeline.
//
//  SWIFT TERMS IN THIS FILE:
//  - AppEnum: Enum exposed to the system UI as a picker (with display names).
//  - AppEntity: A selectable “thing” (here: a card name) in configuration UI.
//  - EntityQuery: Supplies the list of entities the picker can choose from.
//  - WidgetConfigurationIntent: Intent type specialized for widget options.
//  - @Parameter: Declares a configurable field shown in Edit Widget.
//  - Set: Unordered unique collection (used for fast “is this card excluded?” checks).
//  - async throws: Query methods may suspend and may fail.
//

import AppIntents
import WidgetKit

// MARK: - Period picker (Week / Month)

/// Time range options for spend widgets, shown as a system picker.
///
/// `AppEnum` + `String` raw value: each case has a stable string id and
/// human-readable `caseDisplayRepresentations` for the Edit Widget UI.
enum SpendPeriodOption: String, AppEnum {
    case week
    case month

    /// Name of this enum type in the configuration UI (“Time Range”).
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Time Range")
    }

    /// Label for each case in the picker.
    static var caseDisplayRepresentations: [SpendPeriodOption: DisplayRepresentation] {
        [
            .week: DisplayRepresentation(title: "This week"),
            .month: DisplayRepresentation(title: "This month")
        ]
    }

    /// Map widget config option → SharedStore’s SnapshotPeriod used for data loading.
    var snapshotPeriod: SnapshotPeriod {
        switch self {
        case .week: return .week
        case .month: return .month
        }
    }
}

// MARK: - Card entity (hide from breakdown only)

/// One payment method / card the user can hide from the per-card list.
///
/// `AppEntity` requires a unique `id` and display info so the multi-select
/// parameter can list and store chosen cards.
struct PaymentMethodEntity: AppEntity {
    /// Stable identity (here: the card display name string itself).
    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    /// How this entity appears in the picker row.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    /// Default query used by the system to resolve and suggest entities.
    static var defaultQuery = PaymentMethodQuery()
}

/// Loads card names from SharedStore for the configuration multi-select.
///
/// `EntityQuery` methods are async throws so they can load data off the main
/// path if needed (here we just map strings to entities).
struct PaymentMethodQuery: EntityQuery {
    /// Resolve entities for previously saved ids (e.g. after relaunch).
    func entities(for identifiers: [PaymentMethodEntity.ID]) async throws -> [PaymentMethodEntity] {
        // map: transform each id string into a PaymentMethodEntity.
        identifiers.map { PaymentMethodEntity(id: $0, name: $0) }
    }

    /// Suggestions shown when the user opens the “Hide cards” picker.
    func suggestedEntities() async throws -> [PaymentMethodEntity] {
        SharedStore.allPaymentMethods().map { name in
            PaymentMethodEntity(id: name, name: name)
        }
    }
}

// MARK: - Widget configuration intent

/// Edit Widget options for the Total Spend home-screen widget.
///
/// Conforms to `WidgetConfigurationIntent` so it plugs into
/// `AppIntentConfiguration` / `AppIntentTimelineProvider`.
struct FinanceWizardConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Total Spend" }
    static var description: IntentDescription {
        IntentDescription("Choose week or month. Hide cards from the card list only — Total Spend stays the full period total.")
    }

    /// Week vs month. `@Parameter` makes this editable in the widget UI.
    @Parameter(title: "Time range", default: .month)
    var period: SpendPeriodOption

    // Hides cards from the per-card breakdown only (not from Total Spend)
    @Parameter(title: "Hide cards", default: [])
    var excludedCards: [PaymentMethodEntity]

    /// Convenience: ids of excluded cards as a Set for O(1) membership checks.
    var excludedCardNames: Set<String> {
        Set(excludedCards.map(\.id))
    }
}
