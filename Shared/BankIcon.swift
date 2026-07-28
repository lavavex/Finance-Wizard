//
//  BankIcon.swift
//  Finance Wizard
//
//  List tiles and detail headers use the institution logo from Plaid
//  (InstitutionLogoCache). Opaque app-icon logos full-bleed so their baked
//  background fills the tile; transparent marks pad on a matched brand color.
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

    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(logo != nil ? AnyShapeStyle(brandColor) : AnyShapeStyle(brandColor.gradient))
            .overlay {
                if let logo {
                    if fullBleed {
                        // App-icon style (X Money black, Amex blue tile) — fill the square
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(shape)
                    } else {
                        // Transparent Plaid mark — pad on matched brand color
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
            .onChange(of: institutionId) { _, _ in refresh(requestFetch: true) }
            .onChange(of: institutionName) { _, _ in refresh(requestFetch: true) }
            .onReceive(NotificationCenter.default.publisher(for: .institutionLogoDidUpdate)) { note in
                let updatedID = note.userInfo?["institutionID"] as? String
                if updatedID == nil || updatedID == institutionId || institutionId == nil {
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

        // Opaque logo canvas → sample edges so tile matches icon (not a mismatched primary_color).
        if let resolved {
            let opaque = InstitutionLogoCache.logoHasOpaqueCanvas(resolved) || prefersAppleFullBleed
            fullBleed = opaque
            if let hex = InstitutionLogoCache.sampleBackgroundHex(from: resolved),
               let sampled = Color(hex: hex) {
                brandColor = sampled
                // Persist only when different (avoid notification refresh loops)
                InstitutionLogoCache.persistBrandColorIfNeeded(
                    institutionID: institutionId,
                    name: institutionName ?? displayName ?? paymentMethod,
                    hex: hex
                )
            } else {
                brandColor = cachedBrandColor()
            }
        } else {
            fullBleed = false
            brandColor = cachedBrandColor()
        }

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
            refresh(requestFetch: false)
            tick &+= 1
        }
        .id(tick)
    }

    private func refresh(requestFetch: Bool) {
        let resolved = InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
        logo = resolved

        if let resolved {
            let opaque = InstitutionLogoCache.logoHasOpaqueCanvas(resolved)
                || (institutionId == "local:apple-card")
                || (institutionName?.localizedCaseInsensitiveContains("apple") == true)
                || displayName.localizedCaseInsensitiveContains("apple")
            fullBleed = opaque
            if let hex = InstitutionLogoCache.sampleBackgroundHex(from: resolved),
               let sampled = Color(hex: hex) {
                brandColor = sampled
                InstitutionLogoCache.persistBrandColorIfNeeded(
                    institutionID: institutionId,
                    name: institutionName ?? displayName,
                    hex: hex
                )
            } else {
                brandColor = InstitutionLogoCache.primaryColor(institutionID: institutionId)
                    ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
                    ?? Color(red: 0.22, green: 0.24, blue: 0.28)
            }
        } else {
            fullBleed = false
            brandColor = InstitutionLogoCache.primaryColor(institutionID: institutionId)
                ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
                ?? Color(red: 0.22, green: 0.24, blue: 0.28)
        }

        monogram = InstitutionLogoCache.monogram(
            institutionID: institutionId,
            name: institutionName ?? displayName
        )
        if logo == nil, requestFetch {
            InstitutionLogoCache.ensureLogo(institutionID: institutionId, name: institutionName)
        }
    }
}
