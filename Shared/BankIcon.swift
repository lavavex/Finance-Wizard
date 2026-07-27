//
//  BankIcon.swift
//  Finance Wizard
//
//  List tiles and detail headers use the institution logo from Plaid
//  (cached via InstitutionLogoCache). No fake product card art.
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

    private var logo: UIImage? {
        InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
            ?? InstitutionLogoCache.logoImage(institutionName: paymentMethod)
            ?? InstitutionLogoCache.logoImage(institutionName: displayName)
    }

    private var brandColor: Color {
        InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)
    }

    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(brandColor.gradient)
            .overlay {
                if let logo {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.18)
                } else {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(displayName ?? paymentMethod)
    }
}

/// Simple detail header: logo + name (not a fake plastic card).
struct InstitutionLogoHeader: View {
    var displayName: String
    var institutionId: String?
    var institutionName: String?
    var mask: String?
    var size: CGFloat = 72

    private var logo: UIImage? {
        InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
    }

    private var brandColor: Color {
        InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
            ?? Color(red: 0.22, green: 0.24, blue: 0.28)
    }

    var body: some View {
        HStack(spacing: 16) {
            let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            shape
                .fill(brandColor.gradient)
                .frame(width: size, height: size)
                .overlay {
                    if let logo {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.18)
                    } else {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: size * 0.36, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }

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
    }
}
