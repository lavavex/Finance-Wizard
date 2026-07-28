//
//  InstitutionLogoCache.swift
//  Finance Wizard
//
//  Caches Plaid institution logos from /institutions/get_by_id.
//  Files live under the App Group; small metadata in standard UserDefaults.
//

import Foundation
import UIKit
import SwiftUI

/// Posted on the main queue when a logo is written so views can refresh.
extension Notification.Name {
    static let institutionLogoDidUpdate = Notification.Name("InstitutionLogoCache.didUpdate")
    /// App target should fetch from Plaid and call `store` (Shared has no Plaid client).
    static let institutionLogoNeedsFetch = Notification.Name("InstitutionLogoCache.needsFetch")
}

enum InstitutionLogoCache {
    private static let colorPrefix = "plaid.color."
    private static let namePrefix = "plaid.instName."
    private static let memoryLogos = NSCache<NSString, UIImage>()
    private static var inFlight = Set<String>()
    private static let lock = NSLock()
    private static var didSeedBundled = false

    // MARK: - Bundled logos (screenshot-cleaned assets)

    /// Seed known brand marks shipped in the app bundle (e.g. Apple Card).
    /// Safe to call often — runs once per process.
    static func seedBundledLogos() {
        lock.lock()
        if didSeedBundled {
            lock.unlock()
            return
        }
        didSeedBundled = true
        lock.unlock()

        seedAppleCardLogo()
    }

    /// Force re-seed (e.g. after asset update). Overwrites disk cache for Apple Card.
    static func reseedAppleCardLogo() {
        seedAppleCardLogo(force: true)
    }

    private static func seedAppleCardLogo(force: Bool = false) {
        let id = "local:apple-card"
        if !force, logoImage(institutionID: id) != nil { return }

        // Asset lives in the app target; nil in widget process is fine (disk may already exist).
        guard let image = UIImage(named: "AppleCardLogo"),
              let data = image.pngData(), !data.isEmpty else {
            return
        }

        storeImageData(
            data,
            institutionID: id,
            name: "Apple Card",
            primaryColorHex: "#1C1C1E"
        )
        // Extra name aliases used by CSV / labels
        for alias in ["apple card", "apple", "applecard"] {
            writeLogoData(data, key: "name:" + alias)
            UserDefaults.standard.set(id, forKey: "plaid.aliasId." + alias)
            UserDefaults.standard.set("#1C1C1E", forKey: colorPrefix + "name:" + alias)
        }
        memoryLogos.setObject(image, forKey: id as NSString)
    }

    /// Store raw image bytes (PNG/JPEG) as the institution logo.
    static func storeImageData(
        _ data: Data,
        institutionID: String,
        name: String?,
        primaryColorHex: String?
    ) {
        let id = institutionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !data.isEmpty else { return }

        let defaults = UserDefaults.standard
        let resolvedHex: String? = {
            if let hex = primaryColorHex, !hex.isEmpty { return normalizedHex(hex) }
            if let name, let brand = brandFallbackHex(for: name) { return brand }
            return brandFallbackHex(forInstitutionID: id)
        }()

        if let hex = resolvedHex {
            defaults.set(hex, forKey: colorPrefix + id)
        }
        if let name, !name.isEmpty {
            defaults.set(name, forKey: namePrefix + id)
            if let hex = resolvedHex {
                defaults.set(hex, forKey: colorPrefix + "name:" + name.lowercased())
            }
            for alias in nameAliases(for: name) {
                defaults.set(id, forKey: "plaid.aliasId." + alias)
                if let hex = resolvedHex {
                    defaults.set(hex, forKey: colorPrefix + "name:" + alias)
                }
                writeLogoData(data, key: "name:" + alias)
            }
        }

        writeLogoData(data, key: id)
        if let img = UIImage(data: data) {
            memoryLogos.setObject(img, forKey: id as NSString)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .institutionLogoDidUpdate,
                object: nil,
                userInfo: ["institutionID": id, "name": name as Any]
            )
        }
    }

    // MARK: - Write

    static func store(
        institutionID: String,
        name: String?,
        logoBase64: String?,
        primaryColorHex: String?
    ) {
        let id = institutionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let defaults = UserDefaults.standard
        var didChange = false

        let imageData = decodeImageData(logoBase64)
        let decodedImage = imageData.flatMap { UIImage(data: $0) }

        // Background tile color: Plaid primary_color → sample from logo → name/id fallback.
        // When a logo lands successfully, the square behind it always gets a matched color.
        let resolvedHex: String? = resolveBrandHex(
            primaryColorHex: primaryColorHex,
            name: name,
            institutionID: id,
            image: decodedImage
        )

        if let hex = resolvedHex {
            defaults.set(hex, forKey: colorPrefix + id)
            didChange = true
        }
        if let name, !name.isEmpty {
            defaults.set(name, forKey: namePrefix + id)
            if let hex = resolvedHex {
                defaults.set(hex, forKey: colorPrefix + "name:" + name.lowercased())
            }
            for alias in nameAliases(for: name) {
                defaults.set(id, forKey: "plaid.aliasId." + alias)
                if let hex = resolvedHex {
                    defaults.set(hex, forKey: colorPrefix + "name:" + alias)
                }
            }
            didChange = true
        }

        if let imageData, !imageData.isEmpty {
            writeLogoData(imageData, key: id)
            if let name, !name.isEmpty {
                for alias in nameAliases(for: name) {
                    writeLogoData(imageData, key: "name:" + alias)
                }
            }
            if let img = decodedImage {
                memoryLogos.setObject(img, forKey: id as NSString)
            }
            didChange = true
        }

        // Always notify so monogram + brand color refresh even when logo is null.
        if didChange {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .institutionLogoDidUpdate,
                    object: nil,
                    userInfo: ["institutionID": id, "name": name as Any]
                )
            }
        }
    }

    /// Resolve the square fill behind a bank mark.
    /// Opaque app-icon logos: **always** sample the logo canvas first so the tile
    /// matches (X Money black, Amex blue) instead of a mismatched Plaid primary.
    private static func resolveBrandHex(
        primaryColorHex: String?,
        name: String?,
        institutionID: String,
        image: UIImage?
    ) -> String? {
        if let image, logoHasOpaqueCanvas(image), let sampled = sampleBackgroundHex(from: image) {
            return sampled
        }
        if let hex = primaryColorHex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty {
            return normalizedHex(hex)
        }
        if let image, let sampled = sampleBackgroundHex(from: image) {
            return sampled
        }
        if let name, let brand = brandFallbackHex(for: name) { return brand }
        return brandFallbackHex(forInstitutionID: institutionID)
    }

    /// True when corners are solid (Plaid / brand app-icon tiles with a baked background).
    /// Those should full-bleed; transparent-mark logos should pad on brand color.
    static func logoHasOpaqueCanvas(_ image: UIImage) -> Bool {
        guard let sample = rasterSample(image, size: 24) else { return false }
        let corners = [(0, 0), (23, 0), (0, 23), (23, 23), (12, 0), (12, 23), (0, 12), (23, 12)]
        var opaque = 0
        for (x, y) in corners {
            if sample.alpha(x, y) > 0.85 { opaque += 1 }
        }
        return opaque >= 6
    }

    /// Sample a logo PNG for a sensible tile background (#RRGGBB).
    /// Prefers opaque edge/corner colors (letterboxed marks); else a saturated
    /// average of non-white logo pixels (works for transparent-bg bank marks).
    static func sampleBackgroundHex(from image: UIImage) -> String? {
        guard let sample = rasterSample(image, size: 48) else { return nil }
        return sample.backgroundHex()
    }

    // MARK: - Pixel sampling

    private struct RasterSample {
        let w: Int
        let h: Int
        let raw: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            let o = (y * w + x) * 4
            return CGFloat(raw[o + 3]) / 255
        }

        func rgba(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let o = (y * w + x) * 4
            let a = CGFloat(raw[o + 3]) / 255
            let r = a > 0.01 ? CGFloat(raw[o]) / 255 / a : 0
            let g = a > 0.01 ? CGFloat(raw[o + 1]) / 255 / a : 0
            let b = a > 0.01 ? CGFloat(raw[o + 2]) / 255 / a : 0
            return (min(1, r), min(1, g), min(1, b), a)
        }

        func backgroundHex() -> String? {
            let w = self.w
            let h = self.h
            // 1) Opaque edge / corner samples → logo has a solid canvas
            let edgePoints: [(Int, Int)] = [
                (0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
                (w / 2, 0), (w / 2, h - 1), (0, h / 2), (w - 1, h / 2),
                (2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3),
                (4, 4), (w - 5, 4), (4, h - 5), (w - 5, h - 5)
            ]
            var edgeR: CGFloat = 0, edgeG: CGFloat = 0, edgeB: CGFloat = 0
            var edgeCount: CGFloat = 0
            for (x, y) in edgePoints {
                let p = rgba(max(0, min(w - 1, x)), max(0, min(h - 1, y)))
                if p.a > 0.85 {
                    edgeR += p.r; edgeG += p.g; edgeB += p.b
                    edgeCount += 1
                }
            }
            if edgeCount >= 3 {
                return InstitutionLogoCache.hexString(
                    r: edgeR / edgeCount, g: edgeG / edgeCount, b: edgeB / edgeCount
                )
            }

            // 2) Transparent canvas — average saturated non-white opaque pixels
            var sumR: CGFloat = 0, sumG: CGFloat = 0, sumB: CGFloat = 0
            var weight: CGFloat = 0
            let step = max(1, min(w, h) / 16)
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let p = rgba(x, y)
                    if p.a > 0.5 {
                        let maxC = max(p.r, p.g, p.b)
                        let minC = min(p.r, p.g, p.b)
                        let sat = maxC > 0.01 ? (maxC - minC) / maxC : 0
                        let lum = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
                        if lum < 0.92, lum > 0.08 {
                            let wgt = 0.35 + sat * 1.5
                            sumR += p.r * wgt
                            sumG += p.g * wgt
                            sumB += p.b * wgt
                            weight += wgt
                        }
                    }
                    x += step
                }
                y += step
            }
            if weight > 0.01 {
                return InstitutionLogoCache.hexString(
                    r: sumR / weight, g: sumG / weight, b: sumB / weight
                )
            }
            return "#2C2C2E"
        }
    }

    private static func rasterSample(_ image: UIImage, size: Int) -> RasterSample? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        guard let cg = scaled.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        var raw = [UInt8](repeating: 0, count: h * w * 4)
        guard let ctx = CGContext(
            data: &raw,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RasterSample(w: w, h: h, raw: raw)
    }

    fileprivate static func hexString(r: CGFloat, g: CGFloat, b: CGFloat) -> String {
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, ri)), max(0, min(255, gi)), max(0, min(255, bi)))
    }

    /// Write brand color only when it changes (avoids refresh loops from BankIcon).
    static func persistBrandColorIfNeeded(
        institutionID: String?,
        name: String?,
        hex: String
    ) {
        let id = (institutionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nhex = normalizedHex(hex)
        let defaults = UserDefaults.standard
        var changed = false
        if !id.isEmpty {
            let existing = defaults.string(forKey: colorPrefix + id)
            if existing?.caseInsensitiveCompare(nhex) != .orderedSame {
                defaults.set(nhex, forKey: colorPrefix + id)
                changed = true
            }
        }
        if let name, !name.isEmpty {
            let key = colorPrefix + "name:" + name.lowercased()
            if defaults.string(forKey: key)?.caseInsensitiveCompare(nhex) != .orderedSame {
                defaults.set(nhex, forKey: key)
                changed = true
            }
            for alias in nameAliases(for: name) {
                let akey = colorPrefix + "name:" + alias
                if defaults.string(forKey: akey)?.caseInsensitiveCompare(nhex) != .orderedSame {
                    defaults.set(nhex, forKey: akey)
                    changed = true
                }
                if !id.isEmpty {
                    defaults.set(id, forKey: "plaid.aliasId." + alias)
                }
            }
        }
        if changed, !id.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .institutionLogoDidUpdate,
                    object: nil,
                    userInfo: ["institutionID": id, "name": name as Any]
                )
            }
        }
    }

    // MARK: - Read

    static func logoImage(institutionID: String?) -> UIImage? {
        guard let institutionID, !institutionID.isEmpty else { return nil }
        // Lazy seed so first Apple Card tile works even before app start hook runs.
        if institutionID == "local:apple-card" {
            seedBundledLogos()
        }
        if let cached = memoryLogos.object(forKey: institutionID as NSString) {
            return cached
        }
        if let data = readLogoData(key: institutionID), let img = UIImage(data: data) {
            memoryLogos.setObject(img, forKey: institutionID as NSString)
            return img
        }
        // Legacy UserDefaults base64
        if let b64 = UserDefaults.standard.string(forKey: "plaid.logo." + institutionID),
           let data = decodeImageData(b64),
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
        if lower.contains("apple") {
            seedBundledLogos()
        }

        if let data = readLogoData(key: "name:" + lower), let img = UIImage(data: data) {
            return img
        }
        if let id = UserDefaults.standard.string(forKey: "plaid.aliasId." + lower),
           let img = logoImage(institutionID: id) {
            return img
        }
        for alias in nameAliases(for: institutionName) {
            if let data = readLogoData(key: "name:" + alias), let img = UIImage(data: data) {
                return img
            }
            if let id = UserDefaults.standard.string(forKey: "plaid.aliasId." + alias),
               let img = logoImage(institutionID: id) {
                return img
            }
        }
        if let b64 = UserDefaults.standard.string(forKey: "plaid.logo.name:" + lower),
           let data = decodeImageData(b64),
           let img = UIImage(data: data) {
            writeLogoData(data, key: "name:" + lower)
            return img
        }
        return nil
    }

    static func primaryColor(institutionID: String?) -> Color? {
        guard let institutionID, !institutionID.isEmpty else { return nil }
        if let hex = UserDefaults.standard.string(forKey: colorPrefix + institutionID) {
            return Color(hex: hex)
        }
        if let name = UserDefaults.standard.string(forKey: namePrefix + institutionID) {
            if let color = primaryColor(institutionName: name) { return color }
        }
        if let hex = brandFallbackHex(forInstitutionID: institutionID) {
            return Color(hex: hex)
        }
        return nil
    }

    static func primaryColor(institutionName: String?) -> Color? {
        guard let institutionName else { return nil }
        let lower = institutionName.lowercased()
        if let hex = UserDefaults.standard.string(forKey: colorPrefix + "name:" + lower) {
            return Color(hex: hex)
        }
        for alias in nameAliases(for: institutionName) {
            if let hex = UserDefaults.standard.string(forKey: colorPrefix + "name:" + alias) {
                return Color(hex: hex)
            }
            if let id = UserDefaults.standard.string(forKey: "plaid.aliasId." + alias),
               let hex = UserDefaults.standard.string(forKey: colorPrefix + id) {
                return Color(hex: hex)
            }
        }
        // Hardcoded brand fallbacks so tiles aren't all gray while loading / when Plaid omits logo
        if let hex = brandFallbackHex(for: institutionName) {
            return Color(hex: hex)
        }
        return nil
    }

    /// One- or two-letter monogram when Plaid has no logo (e.g. Chase → "C").
    static func monogram(institutionID: String?, name: String?) -> String {
        if let name, !name.isEmpty {
            let n = name.lowercased()
            if n.contains("chase") { return "C" }
            if n.contains("american express") || n.contains("amex") { return "AX" }
            if n.contains("apple") { return "A" }
            if n.contains("x money") || n == "x" { return "X" }
            if n.contains("capital one") { return "CO" }
            if n.contains("bank of america") || n.contains("bofa") { return "BA" }
            if n.contains("wells fargo") { return "WF" }
            if n.contains("citi") { return "Ci" }
            if n.contains("discover") { return "D" }
            if n.contains("us bank") || n.contains("u.s. bank") { return "US" }
            // First letters of up to two significant words
            let words = name
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count >= 2 || $0.uppercased() == String($0) }
            if words.count >= 2 {
                let a = words[0].prefix(1).uppercased()
                let b = words[1].prefix(1).uppercased()
                return a + b
            }
            if let first = words.first {
                return String(first.prefix(2)).uppercased()
            }
            return String(name.prefix(1)).uppercased()
        }
        if let institutionID {
            switch institutionID {
            case "ins_56": return "C"       // Chase
            case "ins_10": return "AX"      // Amex (common)
            default: break
            }
        }
        return "?"
    }

    static func debugLogoStatus() -> [String: Bool] {
        var result: [String: Bool] = [:]
        guard let dir = logoDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return result
        }
        for file in files where file.hasSuffix(".png") || file.hasSuffix(".img") {
            result[file] = true
        }
        return result
    }

    // MARK: - On-demand fetch (app target handles network)

    /// If no logo on disk, ask the app to fetch from Plaid (see InstitutionLogoFetcher).
    static func ensureLogo(institutionID: String?, name: String?) {
        let id = (institutionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if logoImage(institutionID: id) != nil { return }

        lock.lock()
        if inFlight.contains(id) {
            lock.unlock()
            return
        }
        inFlight.insert(id)
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .institutionLogoNeedsFetch,
                object: nil,
                userInfo: ["institutionID": id, "name": name as Any]
            )
        }
    }

    /// Call from the app after a fetch attempt finishes (success or fail).
    static func markFetchFinished(institutionID: String) {
        lock.lock()
        inFlight.remove(institutionID)
        lock.unlock()
    }

    /// Prefetch logos for every known linked account institution id.
    static func prefetch(accounts: [BankAccount]) {
        var seen = Set<String>()
        for account in accounts {
            guard let id = account.institutionId, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            ensureLogo(institutionID: id, name: account.institutionName)
        }
    }

    // MARK: - Decode helpers

    /// Accepts raw base64, data-URL, or whitespace-padded Plaid payloads.
    private static func decodeImageData(_ logoBase64: String?) -> Data? {
        guard var s = logoBase64?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            s = String(s[s.index(after: comma)...])
        }
        s = s.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        if let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !data.isEmpty {
            return data
        }
        // Some payloads are URL-safe base64
        let urlSafe = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: urlSafe, options: .ignoreUnknownCharacters)
    }

    private static func normalizedHex(_ hex: String) -> String {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("#") { s = "#" + s }
        return s
    }

    /// Brand hex when Plaid omits `primary_color` / `logo` (see Plaid docs: logos optional).
    private static func brandFallbackHex(for name: String) -> String? {
        let n = name.lowercased()
        if n.contains("chase") { return "#114B7D" } // Chase blue
        if n.contains("american express") || n.contains("amex") { return "#006FBF" }
        if n.contains("apple") { return "#262628" }
        if n.contains("x money") { return "#1C1C1E" }
        if n.contains("citi") { return "#0054A4" }
        if n.contains("capital one") { return "#D61F26" }
        if n.contains("bank of america") || n.contains("bofa") { return "#012169" }
        if n.contains("wells fargo") { return "#D71E28" }
        if n.contains("discover") { return "#FF6000" }
        if n.contains("us bank") || n.contains("u.s. bank") { return "#0C2074" }
        return nil
    }

    private static func brandFallbackHex(forInstitutionID id: String) -> String? {
        switch id {
        case "ins_56": return "#114B7D" // Chase
        default: return nil
        }
    }

    // MARK: - Disk

    private static func logoDirectory() -> URL? {
        let fm = FileManager.default
        // Prefer app caches (always writable); also mirror to App Group when available
        let appCaches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("InstitutionLogos", isDirectory: true)
        if let appCaches {
            try? fm.createDirectory(at: appCaches, withIntermediateDirectories: true)
        }
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) {
            let groupDir = group.appendingPathComponent("Library/Caches/InstitutionLogos", isDirectory: true)
            try? fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
            return groupDir
        }
        return appCaches
    }

    private static func logoFileURL(key: String) -> URL? {
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return logoDirectory()?.appendingPathComponent(safe + ".img")
    }

    /// Also check legacy .png filenames from earlier builds.
    private static func readLogoData(key: String) -> Data? {
        let fm = FileManager.default
        if let url = logoFileURL(key: key), fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        // Legacy .png path
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if let dir = logoDirectory() {
            let png = dir.appendingPathComponent(safe + ".png")
            if fm.fileExists(atPath: png.path), let data = try? Data(contentsOf: png), !data.isEmpty {
                return data
            }
        }
        // App caches fallback (if group write failed earlier)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("InstitutionLogos", isDirectory: true)
            for ext in ["img", "png"] {
                let url = dir.appendingPathComponent(safe + "." + ext)
                if fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    private static func writeLogoData(_ data: Data, key: String) {
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // Write App Group (widget) + app caches (reliability)
        if let url = logoFileURL(key: key) {
            try? data.write(to: url, options: .atomic)
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("InstitutionLogos", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(safe + ".img")
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func nameAliases(for name: String) -> [String] {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var set: Set<String> = [lower]
        if lower.contains("chase") {
            set.insert("chase")
            set.insert("jpmorgan chase")
            set.insert("jp morgan chase")
            set.insert("jpmorgan chase bank")
        }
        if lower.contains("american express") || lower.contains("amex") {
            set.insert("american express")
            set.insert("amex")
        }
        if lower.contains("x money") {
            set.insert("x money")
        }
        if lower.contains("apple") {
            set.insert("apple")
            set.insert("apple card")
        }
        if lower.contains("capital one") { set.insert("capital one") }
        if lower.contains("bank of america") { set.insert("bank of america") }
        if lower.contains("wells fargo") { set.insert("wells fargo") }
        if lower.contains("citi") {
            set.insert("citi")
            set.insert("citibank")
        }
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
