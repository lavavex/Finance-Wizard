//
//  SplashScreenView.swift
//  Finance Wizard
//
//  Branded launch overlay after the system launch screen.
//

import SwiftUI

/// Full-screen splash shown once at cold start, then fades into the main UI.
struct SplashScreenView: View {
    @State private var logoScale: CGFloat = 0.82
    @State private var logoOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var glow = false

    /// Matches Mika.icon fill (extended sRGB blue).
    private let brandBlue = Color(red: 0.0, green: 0.533, blue: 1.0)
    private let brandBlueDeep = Color(red: 0.0, green: 0.32, blue: 0.78)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [brandBlue, brandBlueDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Soft radial glow behind the mark
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(glow ? 0.28 : 0.12),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 180
                    )
                )
                .frame(width: 360, height: 360)
                .blur(radius: 8)

            VStack(spacing: 20) {
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                VStack(spacing: 6) {
                    Text("Finance Wizard")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Your money, sorted")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .opacity(titleOpacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                logoScale = 1.0
                logoOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.45).delay(0.12)) {
                titleOpacity = 1
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance Wizard")
    }
}

/// Hosts main content under a one-shot splash overlay.
struct RootWithSplash: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            ContentView()
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // Hold long enough to read the brand, short enough not to annoy.
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            withAnimation(.easeInOut(duration: 0.38)) {
                showSplash = false
            }
        }
    }
}

#Preview {
    SplashScreenView()
}
