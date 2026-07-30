//
//  RewardCategory.swift
//  Finance Wizard
//
//  Earn-rate categories for Benefits (separate from general spend categories).
//  Example: "Drugstores" ≠ "Personal Care" for Chase Freedom Unlimited.
//

import Foundation
import SwiftUI

// MARK: - General spend categories (Transactions / charts)

// See KnownCategory.swift — Dining, Gas (Car), Groceries, Shopping, etc.

// MARK: - Reward / benefit earn categories

/// Categories used only for card earn rates & Benefits UI.
enum RewardCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case dining = "Dining"
    case drugstores = "Drugstores"
    case groceries = "Groceries"
    case onlineGrocery = "Online Grocery"
    case gas = "Gas"
    case transit = "Transit"
    case streaming = "Streaming"
    case shopping = "Shopping"
    case onlineRetail = "Online Retail"
    case amazon = "Amazon / Whole Foods"
    case travelPortal = "Travel (Portal)"
    case travelOther = "Travel (Other)"
    case personalCare = "Personal Care"
    case homeInternet = "Home Internet"
    case carInsurance = "Car Insurance"
    case everythingElse = "Everything Else"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dining: return "fork.knife"
        case .drugstores: return "cross.case.fill"
        case .groceries, .onlineGrocery: return "cart.fill"
        case .gas: return "fuelpump.fill"
        case .transit: return "bus.fill"
        case .streaming: return "play.tv.fill"
        case .shopping, .onlineRetail, .amazon: return "bag.fill"
        case .travelPortal, .travelOther: return "airplane"
        case .personalCare: return "heart.text.square.fill"
        case .homeInternet: return "wifi"
        case .carInsurance: return "car.fill"
        case .everythingElse: return "ellipsis.circle.fill"
        }
    }

    /// Short help under each row in the Benefits editor.
    var editorHint: String {
        switch self {
        case .dining: return "Restaurants, takeout, eligible delivery"
        case .drugstores: return "Pharmacies / drugstores (not general personal care)"
        case .groceries: return "Supermarkets / grocery stores"
        case .onlineGrocery: return "Online grocery (excl. Target, Walmart, clubs when noted)"
        case .gas: return "Gas stations, EV charging"
        case .transit: return "Local transit, rideshare, commuting"
        case .streaming: return "Select streaming / digital entertainment"
        case .shopping: return "General retail shopping"
        case .onlineRetail: return "U.S. online retail (e.g. Amex BCE)"
        case .amazon: return "Amazon.com, Whole Foods, Amazon Fresh (Prime Visa)"
        case .travelPortal: return "Booked through issuer travel portal (Chase Travel, etc.)"
        case .travelOther: return "Flights, hotels, travel booked direct"
        case .personalCare: return "Personal care outside drugstores"
        case .homeInternet: return "Internet, cable, phone bills"
        case .carInsurance: return "Auto insurance"
        case .everythingElse: return "Base rate for all other spend"
        }
    }

    static var allNames: [String] { allCases.map(\.rawValue) }

    static func canonicalName(for raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }?.rawValue
    }

    // MARK: - Map general spend → reward earn category

    /// Pick the best reward category for a transaction’s general category + title.
    static func forTransaction(generalCategory: String, title: String = "") -> RewardCategory {
        let g = generalCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.lowercased()

        // Title heuristics first (more specific than general category)
        if looksLikeDrugstore(t) { return .drugstores }
        if looksLikeAmazon(t) { return .amazon }
        if looksLikeTransit(t) { return .transit }
        if looksLikeStreaming(t) { return .streaming }
        if looksLikeGas(t) { return .gas }

        switch g {
        case "dining":
            return .dining
        case "gas (car)", "gas":
            return looksLikeTransit(t) ? .transit : .gas
        case "transit", "transportation":
            return .transit
        case "groceries", "grocery":
            // Online grocery is hard to detect; default to stores
            if t.contains("instacart") || t.contains("amazon fresh") || t.contains("whole foods") {
                return t.contains("amazon") || t.contains("whole foods") ? .amazon : .onlineGrocery
            }
            return .groceries
        case "subscriptions", "subscription":
            return .streaming
        case "entertainment":
            return looksLikeStreaming(t) ? .streaming : .everythingElse
        case "shopping", "retail":
            if looksLikeAmazon(t) { return .amazon }
            if t.contains("http") || t.contains(".com") || t.contains("online") {
                return .onlineRetail
            }
            return .shopping
        case "travel", "flights", "hotels":
            if t.contains("chase travel") || t.contains("chase.com/travel") {
                return .travelPortal
            }
            return .travelOther
        case "health", "medical", "pharmacy":
            return looksLikeDrugstore(t) ? .drugstores : .personalCare
        case "personal care":
            return looksLikeDrugstore(t) ? .drugstores : .personalCare
        case "home internet", "internet", "utilities", "housing", "phone":
            return .homeInternet
        case "car insurance", "insurance":
            return .carInsurance
        case "education", "pets", "gifts & donations", "gifts and donations",
             "fees", "miscellaneous", "misc", "other", "uncategorized", "":
            return .everythingElse
        default:
            // Unknown general category string — try reward name match
            if let match = allCases.first(where: { $0.rawValue.lowercased() == g }) {
                return match
            }
            return .everythingElse
        }
    }

    /// All reward categories that a general spend category might map to (for UI hints).
    static func related(toGeneral generalCategory: String) -> [RewardCategory] {
        let g = generalCategory.lowercased()
        switch g {
        case "dining": return [.dining]
        case "gas (car)", "gas": return [.gas, .transit]
        case "transit": return [.transit]
        case "groceries": return [.groceries, .onlineGrocery, .amazon]
        case "subscriptions": return [.streaming]
        case "entertainment": return [.streaming, .everythingElse]
        case "shopping": return [.shopping, .onlineRetail, .amazon, .drugstores]
        case "travel": return [.travelPortal, .travelOther]
        case "health": return [.drugstores, .personalCare]
        case "personal care": return [.personalCare, .drugstores]
        case "home internet", "utilities", "housing": return [.homeInternet]
        case "car insurance": return [.carInsurance]
        default: return [.everythingElse]
        }
    }

    private static func looksLikeDrugstore(_ t: String) -> Bool {
        let needles = [
            "cvs", "walgreens", "rite aid", "riteaid", "duane reade",
            "drugstore", "drug store", "pharmacy", "pharm ", "rx "
        ]
        return needles.contains { t.contains($0) }
    }

    private static func looksLikeAmazon(_ t: String) -> Bool {
        t.contains("amazon") || t.contains("amzn") || t.contains("whole foods")
            || t.contains("wholefoods") || t.contains("amazon fresh")
            || t.contains("audible")
    }

    private static func looksLikeTransit(_ t: String) -> Bool {
        let needles = [
            "uber", "lyft", "metro", "mta", "transit", "subway", "bus ",
            "rideshare", "ride share", "parking", "toll"
        ]
        return needles.contains { t.contains($0) }
    }

    private static func looksLikeStreaming(_ t: String) -> Bool {
        let needles = [
            "netflix", "hulu", "disney+", "disney plus", "spotify", "apple music",
            "apple tv", "hbo", "max.com", "paramount", "peacock", "youtube premium",
            "prime video"
        ]
        return needles.contains { t.contains($0) }
    }

    private static func looksLikeGas(_ t: String) -> Bool {
        let needles = [
            "shell", "chevron", "exxon", "mobil", "bp ", "arco", "costco gas",
            "gas station", "fuel", "ev charging", "chargepoint", "electrify"
        ]
        return needles.contains { t.contains($0) }
    }
}

// MARK: - Style

extension CategoryStyle {
    /// Color for a reward earn category (reuses general palette where it fits).
    static func color(forReward category: String) -> Color {
        if let rc = RewardCategory.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(category) == .orderedSame
        }) {
            switch rc {
            case .dining: return foodAndDrink
            case .drugstores, .personalCare: return health
            case .groceries, .onlineGrocery, .shopping, .onlineRetail, .amazon: return shopping
            case .gas, .transit: return transportation
            case .travelPortal, .travelOther: return travel
            case .streaming, .homeInternet, .carInsurance: return services
            case .everythingElse: return other
            }
        }
        return color(for: category)
    }

    static func symbolName(forReward category: String) -> String {
        if let rc = RewardCategory.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(category) == .orderedSame
        }) {
            return rc.systemImage
        }
        return symbolName(for: category)
    }
}
