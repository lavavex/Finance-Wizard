//
//  BankIcon.swift
//  Finance Wizard
//
//  Institution logo tiles. Prefer cached brand color; only sample logo pixels
//  once when no color is stored (avoids list scroll jank).
//

import SwiftUI
import UIKit

/// Rounded logo tile for lists.
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

    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(logo != nil ? AnyShapeStyle(brandColor) : AnyShapeStyle(brandColor.gradient))
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
                            .padding(size * 0.14)
                    }
                } else {
                    Text(monogram)
                        .font(.system(size: monogramFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, size * 0.08)
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .clipped()
            .accessibilityLabel(displayName ?? paymentMethod)
            .onAppear { refresh(requestFetch: true) }
            .onChange(of: institutionId) { _, _ in
                didSample = false
                refresh(requestFetch: true)
            }
            .onChange(of: institutionName) { _, _ in
                didSample = false
                refresh(requestFetch: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .institutionLogoDidUpdate)) { note in
                let updatedID = note.userInfo?["institutionID"] as? String
                if updatedID == nil || updatedID == institutionId || institutionId == nil {
                    didSample = false
                    refresh(requestFetch: false)
                    tick &+= 1
                }
            }
            .id(tick)
    }

    private var monogramFontSize: CGFloat {
        monogram.count > 1 ? size * 0.32 : size * 0.42
    }

    private var prefersAppleFullBleed: Bool {
        let hay = [institutionId, institutionName, paymentMethod, displayName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return hay.contains("apple") || institutionId == "local:apple-card"
    }

    private func refresh(requestFetch: Bool) {
        let resolved = InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
            ?? InstitutionLogoCache.logoImage(institutionName: paymentMethod)
            ?? InstitutionLogoCache.logoImage(institutionName: displayName)
        logo = resolved

        // Always prefer already-stored brand color (no pixel work).
        var color = cachedBrandColor()
        var bleed = prefersAppleFullBleed

        if let resolved {
            // Cheap: only sample when we have no stored color yet (or first paint after logo update).
            let needsSample = !didSample && isPlaceholderGray(color)
            if needsSample {
                bleed = InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || prefersAppleFullBleed
                if let hex = InstitutionLogoCache.sampleBackgroundHex(from: resolved),
                   let sampled = Color(hex: hex) {
                    color = sampled
                    InstitutionLogoCache.persistBrandColorIfNeeded(
                        institutionID: institutionId,
                        name: institutionName ?? displayName ?? paymentMethod,
                        hex: hex
                    )
                }
                didSample = true
            } else if !didSample {
                // Have a stored color; still detect full-bleed once (cached after first call).
                bleed = InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || prefersAppleFullBleed
                didSample = true
            } else {
                // Subsequent refreshes: keep fullBleed state, or re-check cheap cached path
                bleed = fullBleed || InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || prefersAppleFullBleed
            }
        } else {
            didSample = false
            bleed = false
        }

        brandColor = color
        fullBleed = bleed

        monogram = InstitutionLogoCache.monogram(
            institutionID: institutionId,
            name: institutionName ?? displayName ?? paymentMethod
        )

        if logo == nil, requestFetch {
            InstitutionLogoCache.ensureLogo(
                institutionID: institutionId,
                name: institutionName ?? displayName ?? paymentMethod
            )
        }
    }

    private func cachedBrandColor() -> Color {
        InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? InstitutionLogoCache.primaryColor(institutionName: paymentMethod)
            ?? InstitutionLogoCache.primaryColor(institutionName: displayName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)
    }

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
                Text(displayName)
                    .font(.title3.weight(.semibold))
                if let institutionName, !institutionName.isEmpty {
                    Text(institutionName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let mask, !mask.isEmpty {
                    Text("···\(mask)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .onAppear { refresh(requestFetch: true) }
        .onReceive(NotificationCenter.default.publisher(for: .institutionLogoDidUpdate)) { _ in
            didSample = false
            refresh(requestFetch: false)
            tick &+= 1
        }
        .id(tick)
    }

    private func refresh(requestFetch: Bool) {
        let resolved = InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
        logo = resolved

        var color = InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)
        var bleed = (institutionId == "local:apple-card")
            || (institutionName?.localizedCaseInsensitiveContains("apple") == true)
            || displayName.localizedCaseInsensitiveContains("apple")

        if let resolved {
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            let isGray = ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                && abs(r - 0.22) < 0.05 && abs(g - 0.24) < 0.05 && abs(b - 0.28) < 0.05
            if !didSample {
                bleed = InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || bleed
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
                bleed = fullBleed || InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || bleed
            }
        } else {
            didSample = false
            bleed = false
        }

        brandColor = color
        fullBleed = bleed
        monogram = InstitutionLogoCache.monogram(
            institutionID: institutionId,
            name: institutionName ?? displayName
        )
        if logo == nil, requestFetch {
            InstitutionLogoCache.ensureLogo(institutionID: institutionId, name: institutionName)
        }
    }
}
