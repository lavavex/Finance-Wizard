//
//  InstitutionLogoCache.swift
//  Finance Wizard
//
//  Caches Plaid institution logos (base64 PNG from /institutions/get_by_id).
//  Stored as files in the App Group (UserDefaults is too small for many PNGs).
//

import Foundation
import UIKit
import SwiftUI

enum InstitutionLogoCache {
    private static let colorPrefix = "plaid.color."
    private static let namePrefix = "plaid.instName."
    private static let idToNamePrefix = "plaid.instIdName."
    private static let memoryLogos = NSCache<NSString, UIImage>()

    // MARK: - Write

    static func store(
        institutionID: String,
        name: String?,
        logoBase64: String?,
        primaryColorHex: String?
    ) {
        let id = institutionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let defaults = storageDefaults

        if let hex = primaryColorHex, !hex.isEmpty {
            defaults.set(hex, forKey: colorPrefix + id)
        }
        if let name, !name.isEmpty {
            defaults.set(name, forKey: namePrefix + id)
            defaults.set(name, forKey: idToNamePrefix + id)
            if let hex = primaryColorHex, !hex.isEmpty {
                defaults.set(hex, forKey: colorPrefix + "name:" + name.lowercased())
            }
            // Aliases so "Chase" / "CHASE COLLEGE" style labels still resolve
            for alias in nameAliases(for: name) {
                defaults.set(id, forKey: "plaid.aliasId." + alias)
                if let hex = primaryColorHex, !hex.isEmpty {
                    defaults.set(hex, forKey: colorPrefix + "name:" + alias)
                }
            }
        }

        if let b64 = logoBase64, !b64.isEmpty,
           let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           !data.isEmpty {
            writeLogoData(data, key: id)
            if let name, !name.isEmpty {
                for alias in nameAliases(for: name) {
                    writeLogoData(data, key: "name:" + alias)
                }
            }
            if let img = UIImage(data: data) {
                memoryLogos.setObject(img, forKey: id as NSString)
            }
        }
    }

    // MARK: - Read

    static func logoImage(institutionID: String?) -> UIImage? {
        guard let institutionID, !institutionID.isEmpty else { return nil }
        if let cached = memoryLogos.object(forKey: institutionID as NSString) {
            return cached
        }
        if let data = readLogoData(key: institutionID), let img = UIImage(data: data) {
            memoryLogos.setObject(img, forKey: institutionID as NSString)
            return img
        }
        // Legacy UserDefaults fallback (pre disk-cache installs)
        if let b64 = UserDefaults.standard.string(forKey: "plaid.logo." + institutionID),
           let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           let img = UIImage(data: data) {
            writeLogoData(data, key: institutionID)
            memoryLogos.setObject(img, forKey: institutionID as NSString)
            return img
        }
        return nil
    }

    static func logoImage(institutionName: String?) -> UIImage? {
        guard let institutionName, !institutionName.isEmpty else { return nil }
        let lower = institutionName.lowercased()

        // Exact name key
        if let data = readLogoData(key: "name:" + lower), let img = UIImage(data: data) {
            return img
        }
        // Alias map → institution id
        if let id = storageDefaults.string(forKey: "plaid.aliasId." + lower) {
            if let img = logoImage(institutionID: id) { return img }
        }
        // Fuzzy: known brand fragments
        for alias in nameAliases(for: institutionName) {
            if let data = readLogoData(key: "name:" + alias), let img = UIImage(data: data) {
                return img
            }
            if let id = storageDefaults.string(forKey: "plaid.aliasId." + alias),
               let img = logoImage(institutionID: id) {
                return img
            }
        }
        // Legacy UserDefaults by name
        if let b64 = UserDefaults.standard.string(forKey: "plaid.logo.name:" + lower),
           let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           let img = UIImage(data: data) {
            writeLogoData(data, key: "name:" + lower)
            return img
        }
        return nil
    }

    static func primaryColor(institutionID: String?) -> Color? {
        guard let institutionID,
              let hex = storageDefaults.string(forKey: colorPrefix + institutionID)
                ?? UserDefaults.standard.string(forKey: colorPrefix + institutionID) else {
            return nil
        }
        return Color(hex: hex)
    }

    static func primaryColor(institutionName: String?) -> Color? {
        guard let institutionName else { return nil }
        let lower = institutionName.lowercased()
        if let hex = storageDefaults.string(forKey: colorPrefix + "name:" + lower)
            ?? UserDefaults.standard.string(forKey: colorPrefix + "name:" + lower) {
            return Color(hex: hex)
        }
        for alias in nameAliases(for: institutionName) {
            if let hex = storageDefaults.string(forKey: colorPrefix + "name:" + alias) {
                return Color(hex: hex)
            }
            if let id = storageDefaults.string(forKey: "plaid.aliasId." + alias),
               let color = primaryColor(institutionID: id) {
                return color
            }
        }
        return nil
    }

    /// Debug / export: which institutions currently have a cached logo on disk.
    static func debugLogoStatus() -> [String: Bool] {
        var result: [String: Bool] = [:]
        guard let dir = logoDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return result
        }
        for file in files where file.hasSuffix(".png") {
            let key = String(file.dropLast(4))
            result[key] = true
        }
        return result
    }

    // MARK: - Disk

    private static var storageDefaults: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
    }

    private static func logoDirectory() -> URL? {
        let fm = FileManager.default
        let base: URL
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) {
            base = group.appendingPathComponent("Library/Caches/InstitutionLogos", isDirectory: true)
        } else {
            base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("InstitutionLogos", isDirectory: true)
        }
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static func logoFileURL(key: String) -> URL? {
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return logoDirectory()?.appendingPathComponent(safe + ".png")
    }

    private static func writeLogoData(_ data: Data, key: String) {
        guard let url = logoFileURL(key: key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func readLogoData(key: String) -> Data? {
        guard let url = logoFileURL(key: key),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Brand aliases for fuzzy logo lookup (lowercase).
    private static func nameAliases(for name: String) -> [String] {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var set: Set<String> = [lower]
        if lower.contains("chase") {
            set.insert("chase")
            set.insert("jpmorgan chase")
            set.insert("jp morgan chase")
        }
        if lower.contains("american express") || lower == "amex" || lower.contains("amex") {
            set.insert("american express")
            set.insert("amex")
        }
        if lower.contains("x money") || lower == "x" {
            set.insert("x money")
        }
        if lower.contains("capital one") {
            set.insert("capital one")
        }
        if lower.contains("bank of america") {
            set.insert("bank of america")
        }
        if lower.contains("wells fargo") {
            set.insert("wells fargo")
        }
        if lower.contains("citi") {
            set.insert("citi")
            set.insert("citibank")
        }
        // First word (e.g. "Chase" from longer strings)
        if let first = lower.split(separator: " ").first, first.count >= 3 {
            set.insert(String(first))
        }
        return Array(set)
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
