//
//  BankIcon.swift
//  Finance Wizard
//
//  Card faces + list tiles.
//
//  What we CAN use:
//  • Plaid institution logos + brand colors (/institutions/get_by_id metadata)
//  • Original product-colored faces (Freedom-blue, Sapphire-navy, …)
//
//  What we cannot ship by scraping Chase.com:
//  • Official product photography of Freedom / Sapphire / etc. (copyright).
//    Apps that show those either license the art or partner with a data
//    provider — they don’t hotlink Chase marketing assets into the binary.
//

import SwiftUI
import UIKit

// MARK: - List icon

struct BankIconView: View {
    let paymentMethod: String
    var size: CGFloat = 36
    var accountId: String? = nil
    var displayName: String? = nil
    var institutionId: String? = nil
    var institutionName: String? = nil

    private var product: CardProduct {
        let name = displayName
            ?? CardLabelStore.label(paymentMethod: paymentMethod, accountId: accountId)
        return CardLabelStore.product(
            accountId: accountId,
            paymentMethod: paymentMethod,
            displayName: name
        )
    }

    private var logo: UIImage? {
        InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
    }

    private var brandColor: Color? {
        InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
    }

    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        CardProductTile(
            product: product,
            size: size,
            logo: logo,
            brandColor: brandColor
        )
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(displayName ?? paymentMethod)
    }
}

// MARK: - Full card face

struct CardFaceView: View {
    let product: CardProduct
    var displayName: String
    var width: CGFloat = 280
    var institutionId: String? = nil
    var institutionName: String? = nil
    var mask: String? = nil

    private var height: CGFloat { width / 1.586 }
    private var radius: CGFloat { width * 0.06 }

    private var logo: UIImage? {
        InstitutionLogoCache.logoImage(institutionID: institutionId)
            ?? InstitutionLogoCache.logoImage(institutionName: institutionName)
    }

    private var brandColor: Color? {
        InstitutionLogoCache.primaryColor(institutionID: institutionId)
            ?? InstitutionLogoCache.primaryColor(institutionName: institutionName)
    }

    private var colors: [Color] {
        if let brandColor {
            return [brandColor, brandColor.opacity(0.75), Color.black.opacity(0.85)]
        }
        return product.gradient
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        shape
            .fill(
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                // Plastic sheen
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.04),
                            Color.clear,
                            Color.black.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay(alignment: .topLeading) {
                // EMV chip (stylized)
                RoundedRectangle(cornerRadius: width * 0.012, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.90, green: 0.80, blue: 0.45),
                                Color(red: 0.70, green: 0.58, blue: 0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: width * 0.13, height: width * 0.10)
                    .overlay {
                        // Contact pads
                        VStack(spacing: 1) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.black.opacity(0.15))
                                    .frame(height: 1)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(width * 0.08)
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if let logo {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: width * 0.16, height: width * 0.16)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    } else if let accent = product.accentColor {
                        Circle()
                            .fill(accent.opacity(0.9))
                            .frame(width: width * 0.09, height: width * 0.09)
                    }
                }
                .padding(width * 0.08)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: width * 0.015) {
                    Text(displayName)
                        .font(.system(size: width * 0.055, weight: .semibold, design: .rounded))
                        .foregroundStyle(product.monogramColor)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .font(.system(size: width * 0.038, weight: .medium, design: .rounded))
                            .foregroundStyle(product.monogramColor.opacity(0.8))
                            .lineLimit(1)
                        if let mask, !mask.isEmpty {
                            Text("···\(mask)")
                                .font(.system(size: width * 0.038, weight: .medium, design: .monospaced))
                                .foregroundStyle(product.monogramColor.opacity(0.7))
                        }
                    }
                }
                .padding(width * 0.08)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(displayName), \(product.displayName)")
    }
}

// MARK: - Tile

struct CardProductTile: View {
    let product: CardProduct
    var size: CGFloat
    var logo: UIImage? = nil
    var brandColor: Color? = nil

    private var fillColors: [Color] {
        if let brandColor {
            return [brandColor, brandColor.opacity(0.8)]
        }
        return product.gradient
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)

        shape
            .fill(
                LinearGradient(
                    colors: fillColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if let logo {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.18)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                } else if product == .appleCard {
                    Image(systemName: "apple.logo")
                        .font(.system(size: size * 0.40, weight: .medium))
                        .foregroundStyle(product.monogramColor)
                } else if product == .generic {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                } else if product == .amazonPrimeVisa {
                    VStack(spacing: size * 0.02) {
                        Text(product.monogram)
                            .font(.system(size: size * 0.40, weight: .bold, design: .rounded))
                            .foregroundStyle(product.monogramColor)
                        Capsule()
                            .fill(product.accentColor ?? .orange)
                            .frame(width: size * 0.42, height: size * 0.06)
                    }
                } else {
                    Text(product.monogram)
                        .font(.system(size: size * (product.monogram.count > 1 ? 0.30 : 0.42), weight: .bold, design: .rounded))
                        .foregroundStyle(product.monogramColor)
                        .tracking(-0.5)
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
    }
}

// Legacy
enum BankBrand: String, CaseIterable {
    case chase, amex, amazon, xMoney, generic

    static func resolve(from paymentMethod: String) -> BankBrand {
        switch CardProduct.resolve(from: paymentMethod) {
        case .chaseFreedom, .chaseFreedomUnlimited, .chaseFreedomFlex,
             .chaseSapphirePreferred, .chaseSapphireReserve, .chaseSlate:
            return .chase
        case .amexBlueCash, .amexGold, .amexPlatinum:
            return .amex
        case .amazonPrimeVisa:
            return .amazon
        default:
            return .generic
        }
    }
}
