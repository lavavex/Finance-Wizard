//
//  RewardCategory.swift
//  Finance Wizard
//
//  Earn-rate categories for Benefits (separate from general spend categories).
//  Example: "Drugstores" ≠ "Personal Care" for Chase Freedom Unlimited.
//
//  Why two category systems?
//  • KnownCategory  = how you budget (Dining, Health, Shopping…)
//  • RewardCategory = how the card pays cash back / points (Drugstores, Travel Portal…)
//  One purchase can map from a general bucket into a more specific earn bucket.
//

import Foundation
import SwiftUI

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
    /// FIX: several cards pay a flight-only tier (Amex Platinum 5x, Amex Gold 3x,
    /// Sapphire Reserve 4x). Without this bucket the catalog had to either put the
    /// boost on Travel (Other) — over-crediting car rentals and cruises — or drop it
    /// and under-credit flights. Airlines are their own bucket now.
    case flights = "Flights"
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
        case .flights: return "airplane.departure"
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
        case .travelOther: return "Hotels, car rentals, other travel booked direct"
        case .flights: return "Airfare booked direct with the airline"
        case .personalCare: return "Personal care outside drugstores"
        case .homeInternet: return "Internet, cable, phone bills"
        case .carInsurance: return "Auto insurance"
        case .everythingElse: return "Base rate for all other spend"
        }
    }

    static var allNames: [String] { allCases.map(\.rawValue) }

    /// Exact match on display name (case-insensitive); nil if unknown string.
    static func canonicalName(for raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }?.rawValue
    }

    // MARK: - Map general spend → reward earn category

    /// Pick the best reward category for a transaction’s general category + title.
    /// Title heuristics run first (merchant-specific) then general category switch.
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
            if looksLikeTravelPortal(t) {
                return .travelPortal
            }
            // FIX: airfare now routes to its own bucket so cards with a flight-only tier
            // (Platinum 5x, Gold 3x, Reserve 4x) stop paying that rate on car rentals.
            if looksLikeAirline(t) {
                return .flights
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
        case "travel": return [.travelPortal, .flights, .travelOther]
        case "health": return [.drugstores, .personalCare]
        case "personal care": return [.personalCare, .drugstores]
        case "home internet", "utilities", "housing": return [.homeInternet]
        case "car insurance": return [.carInsurance]
        default: return [.everythingElse]
        }
    }

    // MARK: - Private title heuristics
    // needles.contains { t.contains($0) } is true if any keyword appears in the title.

    private static func looksLikeDrugstore(_ t: String) -> Bool {
        let needles = [
            "cvs", "walgreens", "rite aid", "riteaid", "duane reade",
            "drugstore", "drug store", "pharmacy", "pharm ", "rx "
        ]
        return needles.contains { t.contains($0) }
    }

    private static func looksLikeAmazon(_ t: String) -> Bool {
        // FIX: dropped "audible". Audible is billed separately and is not an eligible
        // Amazon merchant for Prime Visa's 5%, so it was over-crediting subscriptions.
        // OLD:
        // t.contains("amazon") || t.contains("amzn") || t.contains("whole foods")
        //     || t.contains("wholefoods") || t.contains("amazon fresh")
        //     || t.contains("audible")
        t.contains("amazon") || t.contains("amzn") || t.contains("whole foods")
            || t.contains("wholefoods") || t.contains("amazon fresh")
    }

    private static func looksLikeTransit(_ t: String) -> Bool {
        // FIX: "uber" matched "Uber Eats", and because title heuristics run before the
        // general-category switch, food delivery was booked as Transit. That silently
        // under-paid every dining tier (Amex Gold 4x, Freedom Unlimited 3x). Uber Eats
        // now falls through to the Dining branch; Uber rides still match.
        if t.contains("uber eats") || t.contains("ubereats") { return false }
        let needles = [
            "uber", "lyft", "metro", "mta", "transit", "subway", "bus ",
            "rideshare", "ride share", "parking", "toll"
        ]
        return needles.contains { t.contains($0) }
    }

    /// Airfare booked with the airline (not a portal / OTA booking).
    private static func looksLikeAirline(_ t: String) -> Bool {
        if looksLikeTravelPortal(t) { return false }
        let needles = [
            "airline", "air lines", "airways", "airfare", "flight",
            "delta air", "united air", "american airl", "southwest air",
            "jetblue", "alaska air", "spirit air", "frontier air", "hawaiian air",
            "allegiant", "air canada", "lufthansa", "british airways", "aer lingus"
        ]
        return needles.contains { t.contains($0) }
    }

    /// Booked through an issuer travel portal (Chase Travel, Amex Travel, Capital One Travel).
    private static func looksLikeTravelPortal(_ t: String) -> Bool {
        let needles = [
            "chase travel", "chase.com/travel", "amex travel", "americanexpress travel",
            "american express travel", "amextravel", "capital one travel"
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
        // FIX: the bare "mobil" needle matched "t-mobile", so a phone bill was categorised
        // as Gas and picked up any gas boost on the card. Match the ExxonMobil brand
        // explicitly instead of the substring, and never treat a carrier bill as fuel.
        // OLD:
        // let needles = [
        //     "shell", "chevron", "exxon", "mobil", "bp ", "arco", "costco gas",
        //     "gas station", "fuel", "ev charging", "chargepoint", "electrify"
        // ]
        if t.contains("t-mobile") || t.contains("tmobile") { return false }
        let needles = [
            "shell", "chevron", "exxon", "exxonmobil", "exxon mobil", "bp ", "arco",
            "costco gas", "gas station", "fuel", "ev charging", "chargepoint", "electrify"
        ]
        return needles.contains { t.contains($0) }
    }
}

// MARK: - Style extension

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
            case .travelPortal, .travelOther, .flights: return travel
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
