//
//  InstitutionLogoCache.swift
//  Finance Wizard
//
//  Caches Plaid institution logos from /institutions/get_by_id.
//  Files live under the App Group; small metadata in standard UserDefaults.
//
//  File structure (top → bottom):
//  1) Notifications — views refresh; app target fetches when needed
//  2) Memory/disk caches + bundled Apple Card seed
//  3) store / storeImageData — write logos + brand colors
//  4) Pixel sampling — opaque canvas? sample background hex?
//  5) Read path — memoryLogo (main-thread safe) vs loadLogo (async disk)
//  6) monogram / primaryColor / ensureLogo / prefetch
//  7) Disk helpers + name aliases + Color(hex:) parser
//
//  Learning notes:
//  - NSCache is an auto-evicting in-memory cache (system may drop entries under pressure).
//  - App Group = shared container so the widget and app can read the same logo files.
//  - Notification.Name is a typed string for NotificationCenter events.
//  - async/await + Task.detached move heavy disk/decode work off the main thread.
//  - NSLock protects shared mutable sets/flags used from multiple threads.
//

import Foundation
import UIKit
import SwiftUI

/// Posted on the main queue when a logo is written so views can refresh.
/// extension adds static names onto Apple’s Notification.Name type.
extension Notification.Name {
    static let institutionLogoDidUpdate = Notification.Name("InstitutionLogoCache.didUpdate")
    /// App target should fetch from Plaid and call `store` (Shared has no Plaid client).
    static let institutionLogoNeedsFetch = Notification.Name("InstitutionLogoCache.needsFetch")
}

/// Central logo/color cache for bank institution marks.
/// Call memoryLogo on the main thread while scrolling; use loadLogo / ensureLogo for disk + network.
///
/// Storage is intentionally `nonisolated(unsafe)`: NSCache is thread-safe, and mutable
/// flags/sets are always accessed under `lock` (NSLock). That lets disk decode run in
/// `Task.detached` under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor without actor warnings.
enum InstitutionLogoCache {
    /// UserDefaults key prefixes for brand color and institution display name.
    nonisolated private static let colorPrefix = "plaid.color."
    nonisolated private static let namePrefix = "plaid.instName."
    /// Hot path: decoded UIImages keyed by institution id or "name:…".
    /// Closure-initialized static: runs once when first accessed.
    nonisolated(unsafe) private static let memoryLogos: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 256
        return c
    }()
    /// Keys that already miss on disk — skip repeated FileManager / inflate work while scrolling.
    nonisolated(unsafe) private static let missingLogoKeys: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 512
        return c
    }()
    /// Sampled tile hex / full-bleed flag — never re-rasterize the same logo every list row.
    nonisolated(unsafe) private static let sampleHexCache = NSCache<NSString, NSString>()
    nonisolated(unsafe) private static let opaqueCanvasCache = NSCache<NSString, NSNumber>()
    nonisolated(unsafe) private static let aliasListCache = NSCache<NSString, NSArray>()
    /// Institution ids currently waiting on a network fetch (dedupe parallel requests).
    nonisolated(unsafe) private static var inFlight = Set<String>()
    // NSLock is Sendable; no nonisolated(unsafe) needed.
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var didSeedBundled = false
    /// Resolved once — logoDirectory() used to create dirs + stat group container on every tile.
    nonisolated(unsafe) private static var cachedLogoDirectory: URL?
    nonisolated(unsafe) private static var didResolveLogoDirectory = false

    // MARK: - Bundled logos (screenshot-cleaned assets)
    // Some brands (Apple Card) ship in the app asset catalog instead of Plaid.

    /// Seed known brand marks shipped in the app bundle (e.g. Apple Card).
    /// Safe to call often — runs once per process.
    nonisolated static func seedBundledLogos() {
        // Double-checked lock pattern: avoid seeding twice under concurrency
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

    nonisolated private static func seedAppleCardLogo(force: Bool = false) {
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
    /// Also writes name aliases so lookups by “Chase” or “chase bank” can find the same file.
    nonisolated static func storeImageData(
        _ data: Data,
        institutionID: String,
        name: String?,
        primaryColorHex: String?
    ) {
        let id = institutionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !data.isEmpty else { return }

        let defaults = UserDefaults.standard
        // Prefer explicit hex, else known brand colors for name/id
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
            // Alias keys let name-based lookups resolve to this institution id
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
            // NSCache requires NSString keys (Objective-C bridge)
            memoryLogos.setObject(img, forKey: id as NSString)
        }
        // UI listens on the main queue — hop there before posting
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .institutionLogoDidUpdate,
                object: nil,
                userInfo: ["institutionID": id, "name": name as Any]
            )
        }
    }

    // MARK: - Write (from Plaid base64 payload)

    /// Decode Plaid’s logo base64 (if any), resolve brand color, write disk + memory, notify UI.
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
        // flatMap: if data exists, try UIImage(data:); if either is nil, result is nil
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
    /// Opaque app-icon logos: always sample the logo canvas first so the tile
    /// matches (X Money black, Amex blue) instead of a mismatched Plaid primary.
    private static func resolveBrandHex(
        primaryColorHex: String?,
        name: String?,
        institutionID: String,
        image: UIImage?
    ) -> String? {
        // Priority: opaque-canvas sample → Plaid primary → any sample → brand fallbacks
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
        let key = sampleCacheKey(for: image)
        if let cached = opaqueCanvasCache.object(forKey: key as NSString) {
            return cached.boolValue
        }
        // Tiny 16×16 raster is enough to test corner alpha
        guard let sample = rasterSample(image, size: 16) else {
            opaqueCanvasCache.setObject(false as NSNumber, forKey: key as NSString)
            return false
        }
        let last = sample.w - 1
        let mid = sample.w / 2
        // Corners + mid-edges: 8 sample points
        let corners = [(0, 0), (last, 0), (0, last), (last, last), (mid, 0), (mid, last), (0, mid), (last, mid)]
        var opaque = 0
        for (x, y) in corners {
            if sample.alpha(x, y) > 0.85 { opaque += 1 }
        }
        // Most edge samples solid → treat as full-bleed app-icon style
        let result = opaque >= 6
        opaqueCanvasCache.setObject(result as NSNumber, forKey: key as NSString)
        return result
    }

    /// Sample a logo PNG for a sensible tile background (#RRGGBB). Cached per image.
    static func sampleBackgroundHex(from image: UIImage) -> String? {
        let key = sampleCacheKey(for: image)
        if let cached = sampleHexCache.object(forKey: key as NSString) {
            return cached as String
        }
        guard let sample = rasterSample(image, size: 24) else { return nil }
        guard let hex = sample.backgroundHex() else { return nil }
        sampleHexCache.setObject(hex as NSString, forKey: key as NSString)
        return hex
    }

    /// Stable-ish cache key for an image instance (avoids re-sampling identical rasters).
    private static func sampleCacheKey(for image: UIImage) -> String {
        if let cg = image.cgImage {
            // ObjectIdentifier ties to the CGImage identity in memory
            return "cg-\(ObjectIdentifier(cg).hashValue)-\(cg.width)x\(cg.height)"
        }
        return "sz-\(Int(image.size.width))x\(Int(image.size.height))-\(ObjectIdentifier(image).hashValue)"
    }

    // MARK: - Pixel sampling
    // Low-level: shrink the image, read RGBA bytes, estimate a background color.

    /// Tiny RGBA bitmap used only for color/opacity heuristics (not for display).
    private struct RasterSample {
        let w: Int
        let h: Int
        /// Flat byte array: RGBARGBA… length = w * h * 4
        let raw: [UInt8]

        /// Alpha at pixel (x, y) as 0…1.
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            let o = (y * w + x) * 4
            return CGFloat(raw[o + 3]) / 255
        }

        /// Premultiplied storage → un-premultiply when alpha > 0 so colors look correct.
        func rgba(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let o = (y * w + x) * 4
            let a = CGFloat(raw[o + 3]) / 255
            let r = a > 0.01 ? CGFloat(raw[o]) / 255 / a : 0
            let g = a > 0.01 ? CGFloat(raw[o + 1]) / 255 / a : 0
            let b = a > 0.01 ? CGFloat(raw[o + 2]) / 255 / a : 0
            return (min(1, r), min(1, g), min(1, b), a)
        }

        /// Prefer solid edge color; else weighted average of saturated non-white pixels.
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
            // Saturation + luminance filters skip near-white/near-black noise.
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
                        // Rec. 709 luminance approximation
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
            // Last resort neutral dark gray
            return "#2C2C2E"
        }
    }

    /// Draw `image` into a size×size bitmap and return raw RGBA bytes.
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
        // Allocate w*h*4 bytes; CGContext fills them when drawing
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

    /// Format 0…1 RGB components as #RRGGBB.
    /// fileprivate = visible to this file only (RasterSample calls it).
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
    // Fast path: memory only. Slow path: disk decode (prefer off main). Name lookups
    // walk aliases and legacy UserDefaults base64 before giving up.

    /// Memory only — safe on the main thread during scroll (never hits disk / inflate).
    static func memoryLogo(
        institutionID: String? = nil,
        names: [String?] = []
    ) -> UIImage? {
        if let institutionID, !institutionID.isEmpty,
           let img = memoryLogos.object(forKey: institutionID as NSString) {
            return img
        }
        for name in names {
            guard let name, !name.isEmpty else { continue }
            let key = "name:" + name.lowercased()
            if let img = memoryLogos.object(forKey: key as NSString) {
                return img
            }
        }
        return nil
    }

    /// Disk + decode off the caller’s thread when possible. Prefer memoryLogo first on main.
    /// async function: caller uses await. Task.detached runs the body on a background priority.
    static func loadLogo(
        institutionID: String?,
        names: [String?]
    ) async -> UIImage? {
        if let hit = memoryLogo(institutionID: institutionID, names: names) {
            return hit
        }
        return await Task.detached(priority: .userInitiated) {
            if let img = logoImage(institutionID: institutionID) {
                return img
            }
            for name in names {
                if let img = logoImage(institutionName: name) {
                    return img
                }
            }
            return nil
        }.value
    }

    /// Synchronous lookup by Plaid institution id (may hit disk — avoid on main while scrolling).
    nonisolated static func logoImage(institutionID: String?) -> UIImage? {
        guard let institutionID, !institutionID.isEmpty else { return nil }
        // Lazy seed so first Apple Card tile works even before app start hook runs.
        if institutionID == "local:apple-card" {
            seedBundledLogos()
        }
        if let cached = memoryLogos.object(forKey: institutionID as NSString) {
            return cached
        }
        // Negative cache: we already know disk has nothing
        if isMissing(institutionID) { return nil }
        if let data = readLogoData(key: institutionID), let img = UIImage(data: data) {
            remember(img, keys: [institutionID])
            return img
        }
        // Legacy UserDefaults base64 (older app versions stored logos there)
        if let b64 = UserDefaults.standard.string(forKey: "plaid.logo." + institutionID),
           let data = decodeImageData(b64),
           let img = UIImage(data: data) {
            writeLogoData(data, key: institutionID)
            remember(img, keys: [institutionID])
            return img
        }
        markMissing(institutionID)
        return nil
    }

    /// Synchronous lookup by institution display name (aliases + id map).
    nonisolated static func logoImage(institutionName: String?) -> UIImage? {
        guard let institutionName, !institutionName.isEmpty else { return nil }
        let lower = institutionName.lowercased()
        let nameKey = "name:" + lower
        if lower.contains("apple") {
            seedBundledLogos()
        }
        if let cached = memoryLogos.object(forKey: nameKey as NSString) {
            return cached
        }
        if isMissing(nameKey) { return nil }

        if let data = readLogoData(key: nameKey), let img = UIImage(data: data) {
            remember(img, keys: [nameKey])
            return img
        }
        // Name → institution id alias, then load by id
        if let id = UserDefaults.standard.string(forKey: "plaid.aliasId." + lower),
           let img = logoImage(institutionID: id) {
            remember(img, keys: [nameKey])
            return img
        }
        for alias in nameAliases(for: institutionName) {
            let aliasKey = "name:" + alias
            if let cached = memoryLogos.object(forKey: aliasKey as NSString) {
                remember(cached, keys: [nameKey])
                return cached
            }
            if !isMissing(aliasKey),
               let data = readLogoData(key: aliasKey),
               let img = UIImage(data: data) {
                remember(img, keys: [aliasKey, nameKey])
                return img
            }
            if let id = UserDefaults.standard.string(forKey: "plaid.aliasId." + alias),
               let img = logoImage(institutionID: id) {
                remember(img, keys: [aliasKey, nameKey])
                return img
            }
        }
        if let b64 = UserDefaults.standard.string(forKey: "plaid.logo.name:" + lower),
           let data = decodeImageData(b64),
           let img = UIImage(data: data) {
            writeLogoData(data, key: nameKey)
            remember(img, keys: [nameKey])
            return img
        }
        markMissing(nameKey)
        return nil
    }

    /// Put image in memory under each key and clear any “missing” flags for those keys.
    nonisolated private static func remember(_ image: UIImage, keys: [String]) {
        for key in keys where !key.isEmpty {
            memoryLogos.setObject(image, forKey: key as NSString)
            missingLogoKeys.removeObject(forKey: key as NSString)
        }
    }

    nonisolated private static func isMissing(_ key: String) -> Bool {
        missingLogoKeys.object(forKey: key as NSString) != nil
    }

    nonisolated private static func markMissing(_ key: String) {
        missingLogoKeys.setObject(true as NSNumber, forKey: key as NSString)
    }

    /// Brand fill color for tiles, looked up by Plaid institution id.
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

    /// Brand fill color looked up by institution / payment name (with aliases + fallbacks).
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
    // Shared module cannot call Plaid; it posts institutionLogoNeedsFetch.
    // The app’s InstitutionLogoFetcher listens, downloads, then calls store(...).

    /// If no logo on disk, ask the app to fetch from Plaid (see InstitutionLogoFetcher).
    static func ensureLogo(institutionID: String?, name: String?) {
        let id = (institutionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if logoImage(institutionID: id) != nil { return }

        // Deduplicate concurrent ensureLogo calls for the same id
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
        // Decode disk logos off the main thread so the first scroll is already warm.
        warmMemory(accounts: accounts)
    }

    /// Load known account logos into memoryLogos without blocking the UI.
    /// .utility priority = lower urgency than user-initiated work.
    static func warmMemory(accounts: [BankAccount]) {
        let ids = accounts.compactMap(\.institutionId).filter { !$0.isEmpty }
        let names = accounts.map(\.institutionName).filter { !$0.isEmpty }
        Task.detached(priority: .utility) {
            // Set(ids) unique-ifies so we do not decode the same bank twice
            for id in Set(ids) {
                _ = logoImage(institutionID: id)
            }
            for name in Set(names) {
                _ = logoImage(institutionName: name)
            }
        }
    }

    // MARK: - Decode helpers

    /// Accepts raw base64, data-URL, or whitespace-padded Plaid payloads.
    nonisolated private static func decodeImageData(_ logoBase64: String?) -> Data? {
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

    nonisolated private static func normalizedHex(_ hex: String) -> String {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("#") { s = "#" + s }
        return s
    }

    /// Brand hex when Plaid omits `primary_color` / `logo` (see Plaid docs: logos optional).
    nonisolated private static func brandFallbackHex(for name: String) -> String? {
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

    nonisolated private static func brandFallbackHex(forInstitutionID id: String) -> String? {
        switch id {
        case "ins_56": return "#114B7D" // Chase
        default: return nil
        }
    }

    // MARK: - Disk
    // Logos are binary files under App Group caches (shared with widget) with a
    // per-app caches fallback. Keys are sanitized for safe file names.

    /// Directory for logo files; resolved and cached once per process.
    nonisolated private static func logoDirectory() -> URL? {
        if didResolveLogoDirectory { return cachedLogoDirectory }
        lock.lock()
        defer { lock.unlock() }
        // Re-check after acquiring the lock (another thread may have finished first)
        if didResolveLogoDirectory { return cachedLogoDirectory }

        let fm = FileManager.default
        // Prefer App Group (widget) when available; fall back to app caches.
        var resolved: URL?
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) {
            let groupDir = group.appendingPathComponent("Library/Caches/InstitutionLogos", isDirectory: true)
            try? fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
            resolved = groupDir
        } else if let appCaches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("InstitutionLogos", isDirectory: true) {
            try? fm.createDirectory(at: appCaches, withIntermediateDirectories: true)
            resolved = appCaches
        }
        cachedLogoDirectory = resolved
        didResolveLogoDirectory = true
        return resolved
    }

    nonisolated private static func logoFileURL(key: String) -> URL? {
        let safe = sanitizedFileKey(key)
        return logoDirectory()?.appendingPathComponent(safe + ".img")
    }

    /// Replace path-illegal characters so keys like "account:abc" become file-safe.
    nonisolated private static func sanitizedFileKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Also check legacy .png filenames from earlier builds.
    nonisolated private static func readLogoData(key: String) -> Data? {
        let safe = sanitizedFileKey(key)
        if let url = logoFileURL(key: key),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        // Legacy .png path
        if let dir = logoDirectory() {
            let png = dir.appendingPathComponent(safe + ".png")
            if let data = try? Data(contentsOf: png), !data.isEmpty {
                return data
            }
        }
        // App caches fallback (if group write failed earlier)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("InstitutionLogos", isDirectory: true)
            for ext in ["img", "png"] {
                let url = dir.appendingPathComponent(safe + "." + ext)
                if let data = try? Data(contentsOf: url), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    /// Write logo bytes to App Group (widget) and app caches (reliability).
    /// .atomic means write to a temp file then rename (safer if the app crashes mid-write).
    /// All logo files in the App Group cache (filename → bytes) for backup.
    nonisolated static func exportAllLogoFiles() -> [String: Data] {
        guard let dir = logoDirectory() else { return [:] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        var out: [String: Data] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            out[url.lastPathComponent] = data
        }
        return out
    }

    /// Deletes cached logo files (wipe-then-restore).
    nonisolated static func wipeAllLogoFiles() {
        lock.lock()
        memoryLogos.removeAllObjects()
        missingLogoKeys.removeAllObjects()
        lock.unlock()
        guard let dir = logoDirectory() else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes backup logo files into the cache directory.
    nonisolated static func importLogoFiles(_ files: [String: Data]) {
        guard let dir = logoDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            guard !name.contains("/"), !name.contains(".."), !data.isEmpty else { continue }
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated private static func writeLogoData(_ data: Data, key: String) {
        let safe = sanitizedFileKey(key)
        missingLogoKeys.removeObject(forKey: key as NSString)
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

    /// Related lowercase names for the same bank (Chase ↔ JPMorgan Chase, Amex ↔ American Express).
    /// Cached so scrolling does not rebuild the set every row.
    nonisolated private static func nameAliases(for name: String) -> [String] {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = aliasListCache.object(forKey: lower as NSString) as? [String] {
            return cached
        }
        var set: Set<String> = [lower]
        // Dense brand alias table — expand when new institutions need fuzzy name match
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
        // First word often works as a short alias (“chase sapphire” → “chase”)
        if let first = lower.split(separator: " ").first, first.count >= 3 {
            set.insert(String(first))
        }
        let list = Array(set)
        aliasListCache.setObject(list as NSArray, forKey: lower as NSString)
        return list
    }
}

// MARK: - Color hex helper

extension Color {
    /// Failable initializer: Parse #RRGGBB or RRGGBB (or 8-digit with alpha) from Plaid primary_color.
    /// init? means construction can fail and return nil instead of a Color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        // Scanner parses hex text into an integer
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            // Bit masks extract each color channel from the packed integer
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
