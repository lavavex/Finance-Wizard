//
//  SplashScreenView.swift
//  Finance Wizard
//
//  Branded launch overlay shown after the system launch screen, then faded away.
//  Also defines RootWithSplash, which hosts OnboardingGate under that one-shot splash.
//  Uses AppIconImage (a loadable imageset). Image("AppIcon") does not work — that
//  name is an .appiconset, not an imageset.
//

import SwiftUI

/// Cold-start overlay: same 256pt squircle app icon as Welcome before it lifts.
struct SplashScreenView: View {
    @State private var logoScale: CGFloat = 0.82
    @State private var logoOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .clipShape(RoundedRectangle(cornerRadius: 256 * 0.2237, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 20, y: 10)
                .scaleEffect(logoScale)
                .opacity(logoOpacity)
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                logoScale = 1.0
                logoOpacity = 1
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance Wizard")
    }
}

/// One-shot splash over OnboardingGate (Welcome or tabs).
struct RootWithSplash: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            OnboardingGate()
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // Hold ~1.35s, then 0.38s fade. Welcome waits 1.6s so the icon stays put until this lifts.
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
