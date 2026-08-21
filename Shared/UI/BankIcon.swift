//
//  BankIcon.swift
//  Finance Wizard
//
//  Institution logo tiles. Prefer cached brand color; only sample logo pixels
//  once when no color is stored (avoids list scroll jank).
//

import SwiftUI
import UIKit

/// Rounded logo tile for lists (bank / card mark on a brand-colored square).
struct BankIconView: View {
    let paymentMethod: String
    var size: CGFloat = 36
    var accountId: String? = nil
    var displayName: String? = nil
    var institutionId: String? = nil
    var institutionName: String? = nil

    @State private var logo: UIImage?
    @State private var brandColor: Color = Color(red: 0.22, green: 0.24, blue: 0.28)
    @State private var monogram: String = "?"
    @State private var fullBleed = false
    @State private var tick: Int = 0
    @State private var didSample = false
    /// Bumps when a new load starts so older Task results are ignored.
    @State private var loadGeneration = 0

    /// Apple-like continuous corner radius (~22% of size).
    private var cornerRadius: CGFloat { size * 0.2237 }

    /// Names tried when looking up a logo by label (order matters for cache hits).
    private var nameCandidates: [String?] {
        [institutionName, paymentMethod, displayName]
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            // Solid brand color once a logo exists; soft gradient while showing monogram only
            .fill(logo != nil ? AnyShapeStyle(brandColor) : AnyShapeStyle(brandColor.gradient))
            .overlay {
                if let logo {
                    if fullBleed {
                        // Opaque canvas logos fill the whole tile
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(shape)
                    } else {
                        // Transparent marks sit padded on the brand color
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.14)
                    }
                } else {
                    // Fallback: 1–2 letter monogram while logo is missing
                    Text(monogram)
                        .font(.system(size: monogramFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, size * 0.08)
                }
            }
            .overlay {
                // Subtle white rim so dark logos separate from dark backgrounds
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .clipped()
            .accessibilityLabel(displayName ?? paymentMethod)
            .onAppear { refresh(requestFetch: true) }
            // Reset and reload when the linked institution identity changes
            .onChange(of: institutionId) { _, _ in
                didSample = false
                logo = nil
                refresh(requestFetch: true)
            }
            .onChange(of: institutionName) { _, _ in
                didSample = false
                logo = nil
                refresh(requestFetch: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .institutionLogoDidUpdate)) { note in
                let updatedID = note.userInfo?["institutionID"] as? String
                if updatedID == nil || updatedID == institutionId || institutionId == nil {
                    if let img = InstitutionLogoCache.memoryLogo(
                        institutionID: institutionId,
                        names: nameCandidates
                    ) {
                        applyLogo(img)
                        tick &+= 1
                    }
                }
            }
            .id(tick)
    }

    /// Slightly smaller type when the monogram is two letters.
    private var monogramFontSize: CGFloat {
        monogram.count > 1 ? size * 0.32 : size * 0.42
    }

    /// Apple Card assets look best edge-to-edge on the tile.
    private var prefersAppleFullBleed: Bool {
        let hay = [institutionId, institutionName, paymentMethod, displayName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return hay.contains("apple") || institutionId == "local:apple-card"
    }

    /// Update monogram/color; optionally kick off async logo load.
    private func refresh(requestFetch: Bool) {
        monogram = InstitutionLogoCache.monogram(
            institutionID: institutionId,
            name: institutionName ?? displayName ?? paymentMethod
        )
        brandColor = cachedBrandColor()

        // Main-thread path: memory only (no disk / PNG decode while scrolling).
        if let cached = InstitutionLogoCache.memoryLogo(
            institutionID: institutionId,
            names: nameCandidates
        ) {
            applyLogo(cached)
            return
        }

        guard requestFetch else { return }

        loadGeneration &+= 1
        let gen = loadGeneration
        // Capture ids for the Task (avoid racing self across awaits carelessly)
        let id = institutionId
        let names = nameCandidates

        Task { @MainActor in
            let img = await InstitutionLogoCache.loadLogo(institutionID: id, names: names)
            // Drop result if a newer refresh started while we were loading
            guard gen == loadGeneration else { return }
            if let img {
                applyLogo(img)
            } else {
                logo = nil
                didSample = false
                fullBleed = false
                // Ask the app target to fetch from Plaid if still missing
                InstitutionLogoCache.ensureLogo(
                    institutionID: id,
                    name: institutionName ?? displayName ?? paymentMethod
                )
            }
        }
    }

    /// Bind a resolved UIImage and optionally sample its background color once.
    private func applyLogo(_ resolved: UIImage) {
        logo = resolved
        var color = cachedBrandColor()
        var bleed = prefersAppleFullBleed

        if !didSample {
            bleed = InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || prefersAppleFullBleed
            // Only sample pixels when we still have the placeholder gray
            if isPlaceholderGray(color),
               let hex = InstitutionLogoCache.sampleBackgroundHex(from: resolved),
               let sampled = Color(hex: hex) {
                color = sampled
                InstitutionLogoCache.persistBrandColorIfNeeded(
                    institutionID: institutionId,
                    name: institutionName ?? displayName ?? paymentMethod,
                    hex: hex
                )
            }
            didSample = true
        } else {
            bleed = fullBleed || prefersAppleFullBleed
        }

        brandColor = color
        fullBleed = bleed
    }

    /// Brand color from cache/fallbacks; default dark gray if nothing known yet.
    private func cachedBrandColor() -> Color {
        InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? InstitutionLogoCache.primaryColor(institutionName: paymentMethod)
            ?? InstitutionLogoCache.primaryColor(institutionName: displayName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)
    }

    /// True when the color is still the default slate gray placeholder.
    private func isPlaceholderGray(_ color: Color) -> Bool {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return true }
        return abs(r - 0.22) < 0.05 && abs(g - 0.24) < 0.05 && abs(b - 0.28) < 0.05
    }
}

/// Simple detail header: logo + name (not a fake plastic card).
struct InstitutionLogoHeader: View {
    var displayName: String
    var institutionId: String?
    var institutionName: String?
    var mask: String?
    var size: CGFloat = 72

    @State private var logo: UIImage?
    @State private var brandColor: Color = Color(red: 0.22, green: 0.24, blue: 0.28)
    @State private var monogram: String = "?"
    @State private var fullBleed = false
    @State private var tick: Int = 0
    @State private var didSample = false
    @State private var loadGeneration = 0

    var body: some View {
        HStack(spacing: 16) {
            let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            shape
                .fill(logo != nil ? AnyShapeStyle(brandColor) : AnyShapeStyle(brandColor.gradient))
                .frame(width: size, height: size)
                .overlay {
                    if let logo {
                        if fullBleed {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: size, height: size)
                                .clipShape(shape)
                        } else {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFit()
                                .padding(size * 0.16)
                        }
                    } else {
                        Text(monogram)
                            .font(.system(
                                size: monogram.count > 1 ? size * 0.32 : size * 0.42,
                                weight: .bold,
                                design: .rounded
                            ))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                }
                .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                CardText(displayName)
                    .font(.title3.weight(.semibold))
                if let institutionName, !institutionName.isEmpty {
                    Text(institutionName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let mask, !mask.isEmpty {
                    CardText("···\(mask)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .onAppear { refresh(requestFetch: true) }
        .onReceive(NotificationCenter.default.publisher(for: .institutionLogoDidUpdate)) { _ in
            if let img = InstitutionLogoCache.memoryLogo(
                institutionID: institutionId,
                names: [institutionName, displayName]
            ) {
                applyLogo(img)
                tick &+= 1
            }
        }
        .id(tick)
    }

    private func refresh(requestFetch: Bool) {
        monogram = InstitutionLogoCache.monogram(
            institutionID: institutionId,
            name: institutionName ?? displayName
        )
        brandColor = InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)

        if let cached = InstitutionLogoCache.memoryLogo(
            institutionID: institutionId,
            names: [institutionName, displayName]
        ) {
            applyLogo(cached)
            return
        }

        guard requestFetch else { return }

        loadGeneration &+= 1
        let gen = loadGeneration
        let id = institutionId
        let names: [String?] = [institutionName, displayName]

        Task { @MainActor in
            let img = await InstitutionLogoCache.loadLogo(institutionID: id, names: names)
            guard gen == loadGeneration else { return }
            if let img {
                applyLogo(img)
            } else {
                InstitutionLogoCache.ensureLogo(institutionID: id, name: institutionName)
            }
        }
    }

    private func applyLogo(_ resolved: UIImage) {
        logo = resolved
        var color = brandColor
        let appleBleed = (institutionId == "local:apple-card")
            || (institutionName?.localizedCaseInsensitiveContains("apple") == true)
            || displayName.localizedCaseInsensitiveContains("apple")
        var bleed = appleBleed

        if !didSample {
            bleed = InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || appleBleed
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            let isGray = ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                && abs(r - 0.22) < 0.05 && abs(g - 0.24) < 0.05 && abs(b - 0.28) < 0.05
            if isGray,
               let hex = InstitutionLogoCache.sampleBackgroundHex(from: resolved),
               let sampled = Color(hex: hex) {
                color = sampled
                InstitutionLogoCache.persistBrandColorIfNeeded(
                    institutionID: institutionId,
                    name: institutionName ?? displayName,
                    hex: hex
                )
            }
            didSample = true
        } else {
            bleed = fullBleed || appleBleed
        }

        brandColor = color
        fullBleed = bleed
    }
}
