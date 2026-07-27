//
//  BankIcon.swift
//  Finance Wizard
//
//  Dark Mode–style bank “app icons” for payment methods.
//  iOS does not expose Wallet/bank logos to third-party apps, so we render
//  iOS-like rounded squares with brand colors + monograms (optional asset override).
//

import SwiftUI
import UIKit

// Which institution a payment_method string belongs to
enum BankBrand: String, CaseIterable {
    case chase
    case amex
    case amazon
    case xMoney
    case generic

    // Map finance-sync payment_method labels → bank
    static func resolve(from paymentMethod: String) -> BankBrand {
        let m = paymentMethod.lowercased()

        // Amazon / Prime Visa
        if m.contains("prime") || m.contains("amazon") {
            return .amazon
        }
        // American Express (Blue Cash Everyday®, etc.)
        if m.contains("american express") || m.contains("amex") || m.contains("blue cash") {
            return .amex
        }
        // Chase cards & checking
        if m.contains("chase") {
            return .chase
        }
        // X Money (and similar)
        if m.contains("x money") || m == "x" || m.hasPrefix("x ") {
            return .xMoney
        }

        return .generic
    }

    // Optional Asset Catalog name (add images later as BankChase, etc.)
    var assetName: String {
        switch self {
        case .chase: return "BankChase"
        case .amex: return "BankAmex"
        case .amazon: return "BankAmazon"
        case .xMoney: return "BankXMoney"
        case .generic: return "BankGeneric"
        }
    }
}

// iOS Home Screen–style bank icon for lists
struct BankIconView: View {
    // Full payment method string from the transaction / card row
    let paymentMethod: String
    // Side length in points
    var size: CGFloat = 36

    private var brand: BankBrand {
        BankBrand.resolve(from: paymentMethod)
    }

    // Continuous corner radius ~ iOS app icon proportion
    private var cornerRadius: CGFloat {
        size * 0.2237
    }

    var body: some View {
        // Prefer a bundled asset (Any/Dark) if you add one later; else drawn glyph
        if UIImage(named: brand.assetName) != nil {
            Image(brand.assetName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .accessibilityLabel(paymentMethod)
        } else {
            drawnIcon
                .frame(width: size, height: size)
                .accessibilityLabel(paymentMethod)
        }
    }

    // Programmatic dark-mode style icon (no external download)
    @ViewBuilder
    private var drawnIcon: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        switch brand {
        case .chase:
            // Chase-like deep blue tile + white monogram
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.35, blue: 0.55),
                            Color(red: 0.05, green: 0.22, blue: 0.40)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Text("C")
                        .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }

        case .amex:
            // Amex-like blue tile
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.00, green: 0.40, blue: 0.75),
                            Color(red: 0.00, green: 0.25, blue: 0.50)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    Text("AX")
                        .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(-0.5)
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }

        case .amazon:
            // Dark tile + Amazon orange accent (Prime Visa)
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.14, blue: 0.16),
                            Color(red: 0.08, green: 0.08, blue: 0.09)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    VStack(spacing: size * 0.02) {
                        Text("a")
                            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        // Smile-like accent bar
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.60, blue: 0.0))
                            .frame(width: size * 0.45, height: size * 0.06)
                    }
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }

        case .xMoney:
            // Near-black tile + white X
            shape
                .fill(Color(red: 0.08, green: 0.08, blue: 0.08))
                .overlay {
                    Text("𝕏")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                }

        case .generic:
            // Neutral dark gray + card glyph
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.25, green: 0.27, blue: 0.30),
                            Color(red: 0.15, green: 0.16, blue: 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        }
    }
}
