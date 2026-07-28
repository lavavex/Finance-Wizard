//
//  BankIcon.swift
//  Finance Wizard
//
//  List tiles and detail headers use the institution logo from Plaid
//  (InstitutionLogoCache). When a logo is present, the rounded square
//  fill uses Plaid primary_color (or a color sampled from the logo).
//  When Plaid has no logo, shows a brand-color monogram.
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
    @State private var tick: Int = 0

    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            // Solid fill when we have a real logo so the square matches brand color cleanly.
            // Soft gradient only for monogram placeholders.
            .fill(logo != nil ? AnyShapeStyle(brandColor) : AnyShapeStyle(brandColor.gradient))
            .overlay {
                if let logo {
                    if usesFullBleedLogo {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(shape)
                    } else {
                        // Plaid marks are usually transparent — sit on the matched brand square.
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
            .id(tick) // force redraw when logo / color arrives
    }

    private var monogramFontSize: CGFloat {
        monogram.count > 1 ? size * 0.32 : size * 0.42
    }

    /// Apple Card asset is already a rounded square — fill the tile edge-to-edge.
    private var usesFullBleedLogo: Bool {
        let hay = [institutionId, institutionName, paymentMethod, displayName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return hay.contains("apple") || institutionId == "local:apple-card"
    }

    private func refresh(requestFetch: Bool) {
        logo = InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
            ?? InstitutionLogoCache.logoImage(institutionName: paymentMethod)
            ?? InstitutionLogoCache.logoImage(institutionName: displayName)

        brandColor = InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? InstitutionLogoCache.primaryColor(institutionName: paymentMethod)
            ?? InstitutionLogoCache.primaryColor(institutionName: displayName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)

        // If we have a logo but still the generic gray, try sampling once for this session.
        if logo != nil, isGenericGray(brandColor), let logo {
            if let hex = InstitutionLogoCache.sampleBackgroundHex(from: logo),
               let sampled = Color(hex: hex) {
                brandColor = sampled
                // Persist so other tiles / next launch match
                if let institutionId, !institutionId.isEmpty {
                    InstitutionLogoCache.store(
                        institutionID: institutionId,
                        name: institutionName ?? displayName ?? paymentMethod,
                        logoBase64: nil,
                        primaryColorHex: hex
                    )
                }
            }
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

    private func isGenericGray(_ color: Color) -> Bool {
        // Default placeholder RGB ≈ 0.22, 0.24, 0.28
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return abs(r - 0.22) < 0.04 && abs(g - 0.24) < 0.04 && abs(b - 0.28) < 0.04
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
    @State private var tick: Int = 0

    private var fullBleed: Bool {
        (institutionId == "local:apple-card")
            || (institutionName?.localizedCaseInsensitiveContains("apple") == true)
            || displayName.localizedCaseInsensitiveContains("apple")
    }

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
        logo = InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
        brandColor = InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)

        if logo != nil, let logo {
            let ui = UIColor(brandColor)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if ui.getRed(&r, green: &g, blue: &b, alpha: &a),
               abs(r - 0.22) < 0.04, abs(g - 0.24) < 0.04, abs(b - 0.28) < 0.04,
               let hex = InstitutionLogoCache.sampleBackgroundHex(from: logo),
               let sampled = Color(hex: hex) {
                brandColor = sampled
                if let institutionId, !institutionId.isEmpty {
                    InstitutionLogoCache.store(
                        institutionID: institutionId,
                        name: institutionName ?? displayName,
                        logoBase64: nil,
                        primaryColorHex: hex
                    )
                }
            }
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
