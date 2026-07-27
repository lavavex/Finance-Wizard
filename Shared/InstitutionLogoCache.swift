//
//  InstitutionLogoCache.swift
//  Finance Wizard
//
//  Caches Plaid institution logos (base64 PNG from /institutions/get_by_id).
//  These are bank marks licensed through Plaid — not product card photography.
//

import Foundation
import UIKit
import SwiftUI

enum InstitutionLogoCache {
    private static let logoPrefix = "plaid.logo."
    private static let colorPrefix = "plaid.color."
    private static let namePrefix = "plaid.instName."

    // MARK: - Write

    static func store(
        institutionID: String,
        name: String?,
        logoBase64: String?,
        primaryColorHex: String?
    ) {
        let id = institutionID
        if let b64 = logoBase64, !b64.isEmpty {
            UserDefaults.standard.set(b64, forKey: logoPrefix + id)
        }
        if let hex = primaryColorHex, !hex.isEmpty {
            UserDefaults.standard.set(hex, forKey: colorPrefix + id)
        }
        if let name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: namePrefix + id)
        }
        // Also index by lowercase institution name for account rows without id handy
        if let name = name?.lowercased(), !name.isEmpty, let b64 = logoBase64 {
            UserDefaults.standard.set(b64, forKey: logoPrefix + "name:" + name)
            if let hex = primaryColorHex {
                UserDefaults.standard.set(hex, forKey: colorPrefix + "name:" + name)
            }
        }
    }

    // MARK: - Read

    static func logoImage(institutionID: String?) -> UIImage? {
        guard let institutionID, !institutionID.isEmpty else { return nil }
        return decode(UserDefaults.standard.string(forKey: logoPrefix + institutionID))
    }

    static func logoImage(institutionName: String?) -> UIImage? {
        guard let institutionName, !institutionName.isEmpty else { return nil }
        if let img = decode(UserDefaults.standard.string(forKey: logoPrefix + "name:" + institutionName.lowercased())) {
            return img
        }
        // Fuzzy: try known keys that contain the name fragment
        return nil
    }

    static func primaryColor(institutionID: String?) -> Color? {
        guard let institutionID,
              let hex = UserDefaults.standard.string(forKey: colorPrefix + institutionID) else {
            return nil
        }
        return Color(hex: hex)
    }

    static func primaryColor(institutionName: String?) -> Color? {
        guard let institutionName,
              let hex = UserDefaults.standard.string(forKey: colorPrefix + "name:" + institutionName.lowercased()) else {
            return nil
        }
        return Color(hex: hex)
    }

    private static func decode(_ base64: String?) -> UIImage? {
        guard let base64, !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return UIImage(data: data)
    }
}

// MARK: - Color hex helper

extension Color {
    /// Parse #RRGGBB or RRGGBB from Plaid primary_color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        } else {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
