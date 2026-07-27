//
//  CardProduct.swift
//  Finance Wizard
//
//  Named card “faces” for nicknames (Chase Freedom, Sapphire, …).
//  These are original gradients/monograms — not bank-issued artwork
//  (official Chase/Amex card images are copyrighted and can’t be scraped/bundled).
//

import SwiftUI

/// A recognizable product template used for list icons and mini card faces.
enum CardProduct: String, CaseIterable, Identifiable, Sendable {
    case chaseFreedom
    case chaseFreedomUnlimited
    case chaseFreedomFlex
    case chaseSapphirePreferred
    case chaseSapphireReserve
    case chaseSlate
    case amexBlueCash
    case amexGold
    case amexPlatinum
    case amazonPrimeVisa
    case appleCard
    case citiDoubleCash
    case capitalOneVenture
    case capitalOneQuicksilver
    case discoverIt
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chaseFreedom: return "Chase Freedom"
        case .chaseFreedomUnlimited: return "Chase Freedom Unlimited"
        case .chaseFreedomFlex: return "Chase Freedom Flex"
        case .chaseSapphirePreferred: return "Chase Sapphire Preferred"
        case .chaseSapphireReserve: return "Chase Sapphire Reserve"
        case .chaseSlate: return "Chase Slate"
        case .amexBlueCash: return "Amex Blue Cash"
        case .amexGold: return "Amex Gold"
        case .amexPlatinum: return "Amex Platinum"
        case .amazonPrimeVisa: return "Prime Visa"
        case .appleCard: return "Apple Card"
        case .citiDoubleCash: return "Citi Double Cash"
        case .capitalOneVenture: return "Capital One Venture"
        case .capitalOneQuicksilver: return "Capital One Quicksilver"
        case .discoverIt: return "Discover it"
        case .generic: return "Generic card"
        }
    }

    /// Short monogram for the icon tile
    var monogram: String {
        switch self {
        case .chaseFreedom, .chaseFreedomUnlimited, .chaseFreedomFlex: return "CF"
        case .chaseSapphirePreferred, .chaseSapphireReserve: return "CS"
        case .chaseSlate: return "C"
        case .amexBlueCash: return "AX"
        case .amexGold: return "AX"
        case .amexPlatinum: return "AX"
        case .amazonPrimeVisa: return "a"
        case .appleCard: return ""
        case .citiDoubleCash: return "Ci"
        case .capitalOneVenture, .capitalOneQuicksilver: return "C1"
        case .discoverIt: return "D"
        case .generic: return ""
        }
    }

    var gradient: [Color] {
        switch self {
        case .chaseFreedom, .chaseFreedomUnlimited, .chaseFreedomFlex:
            return [
                Color(red: 0.08, green: 0.38, blue: 0.72),
                Color(red: 0.04, green: 0.22, blue: 0.48)
            ]
        case .chaseSapphirePreferred:
            return [
                Color(red: 0.10, green: 0.22, blue: 0.48),
                Color(red: 0.05, green: 0.10, blue: 0.28)
            ]
        case .chaseSapphireReserve:
            return [
                Color(red: 0.12, green: 0.12, blue: 0.14),
                Color(red: 0.05, green: 0.08, blue: 0.16)
            ]
        case .chaseSlate:
            return [
                Color(red: 0.35, green: 0.38, blue: 0.42),
                Color(red: 0.18, green: 0.20, blue: 0.24)
            ]
        case .amexBlueCash:
            return [
                Color(red: 0.00, green: 0.45, blue: 0.82),
                Color(red: 0.00, green: 0.28, blue: 0.55)
            ]
        case .amexGold:
            return [
                Color(red: 0.82, green: 0.68, blue: 0.32),
                Color(red: 0.55, green: 0.42, blue: 0.15)
            ]
        case .amexPlatinum:
            return [
                Color(red: 0.72, green: 0.74, blue: 0.78),
                Color(red: 0.40, green: 0.42, blue: 0.48)
            ]
        case .amazonPrimeVisa:
            return [
                Color(red: 0.16, green: 0.16, blue: 0.18),
                Color(red: 0.08, green: 0.08, blue: 0.10)
            ]
        case .appleCard:
            return [
                Color(red: 0.92, green: 0.92, blue: 0.94),
                Color(red: 0.72, green: 0.74, blue: 0.78)
            ]
        case .citiDoubleCash:
            return [
                Color(red: 0.00, green: 0.35, blue: 0.65),
                Color(red: 0.00, green: 0.18, blue: 0.40)
            ]
        case .capitalOneVenture:
            return [
                Color(red: 0.75, green: 0.12, blue: 0.15),
                Color(red: 0.40, green: 0.05, blue: 0.08)
            ]
        case .capitalOneQuicksilver:
            return [
                Color(red: 0.55, green: 0.58, blue: 0.62),
                Color(red: 0.30, green: 0.32, blue: 0.36)
            ]
        case .discoverIt:
            return [
                Color(red: 0.85, green: 0.35, blue: 0.10),
                Color(red: 0.55, green: 0.15, blue: 0.05)
            ]
        case .generic:
            return [
                Color(red: 0.28, green: 0.30, blue: 0.34),
                Color(red: 0.14, green: 0.15, blue: 0.18)
            ]
        }
    }

    var monogramColor: Color {
        switch self {
        case .appleCard, .amexPlatinum, .amexGold:
            return Color(red: 0.15, green: 0.15, blue: 0.18)
        default:
            return .white
        }
    }

    var accentColor: Color? {
        switch self {
        case .amazonPrimeVisa: return Color(red: 1.0, green: 0.60, blue: 0.0)
        case .chaseSapphirePreferred, .chaseSapphireReserve:
            return Color(red: 0.35, green: 0.55, blue: 0.95)
        case .amexGold: return Color(red: 0.95, green: 0.85, blue: 0.45)
        default: return nil
        }
    }

    /// Infer product from a user nickname / payment method string.
    static func resolve(from label: String) -> CardProduct {
        let m = label.lowercased()

        // More specific first
        if m.contains("freedom unlimited") || m.contains("freedom unl") { return .chaseFreedomUnlimited }
        if m.contains("freedom flex") { return .chaseFreedomFlex }
        if m.contains("freedom") { return .chaseFreedom }
        if m.contains("sapphire reserve") || m.contains("csr") { return .chaseSapphireReserve }
        if m.contains("sapphire") || m.contains("csp") { return .chaseSapphirePreferred }
        if m.contains("slate") && m.contains("chase") { return .chaseSlate }

        if m.contains("blue cash") || m.contains("bce") || m.contains("bcp") { return .amexBlueCash }
        if m.contains("amex gold") || m.contains("american express gold") || (m.contains("gold") && m.contains("amex")) {
            return .amexGold
        }
        if m.contains("platinum") && (m.contains("amex") || m.contains("american express")) {
            return .amexPlatinum
        }
        if m.contains("american express") || m.contains("amex") { return .amexBlueCash }

        if m.contains("prime") || (m.contains("amazon") && m.contains("visa")) { return .amazonPrimeVisa }
        if m.contains("apple card") || m == "apple" { return .appleCard }

        if m.contains("double cash") || (m.contains("citi") && m.contains("double")) { return .citiDoubleCash }
        if m.contains("venture") { return .capitalOneVenture }
        if m.contains("quicksilver") { return .capitalOneQuicksilver }
        if m.contains("discover") { return .discoverIt }

        if m.contains("chase") { return .chaseFreedom } // generic Chase → Freedom-like blue
        if m.contains("citi") { return .citiDoubleCash }
        if m.contains("capital one") { return .capitalOneVenture }

        return .generic
    }

    /// Products shown in the “Card art” picker (exclude generic last).
    static var pickerCases: [CardProduct] {
        allCases
    }
}
