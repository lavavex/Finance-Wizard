//
//  SplashScreenView.swift
//  Finance Wizard
//
//  Branded launch overlay shown after the system launch screen, then faded away.
//  Also defines RootWithSplash, which hosts ContentView under that one-shot splash.
//

import SwiftUI

/// Full-screen splash shown once at cold start, then fades into the main UI.
/// View is a protocol: anything with a `body` that returns UI can be a SwiftUI view.
struct SplashScreenView: View {
    // @State stores view-local mutable state. When it changes, SwiftUI re-renders body.
    // private means only this type can read/write these properties.
    // CGFloat is a floating-point type used for layout sizes and scales.
    @State private var logoScale: CGFloat = 0.82
    @State private var logoOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var glow = false

    /// Brand canvas (matches LaunchBackground / icon fill).
    private let brandCanvas = Color(red: 0.1, green: 0.1, blue: 0.1)

    // body describes the UI. some View is an opaque return type:
    // “this returns some concrete View type” without writing the full nested type.
    var body: some View {
        // ZStack layers views on top of each other (back → front).
        ZStack {
            LinearGradient(
                colors: [brandCanvas, brandCanvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Draw under the status bar / home indicator safe areas.
            .ignoresSafeArea()

            // Soft radial glow behind the logo mark
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            // Ternary: condition ? valueIfTrue : valueIfFalse
                            Color.white.opacity(glow ? 0.16 : 0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 256
                    )
                )
                .frame(width: 360, height: 360)
                .blur(radius: 8)

            // VStack stacks children vertically; spacing is the gap between them.
            VStack(spacing: 20) {
                // Image("SplashLogo") loads an asset from the asset catalog by name.
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 256, height: 256)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                    // scaleEffect / opacity driven by @State so they can animate.
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                VStack(spacing: 6) {
                    Text("Finance Wizard")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .opacity(titleOpacity)
            }
        }
        // onAppear runs when this view first appears on screen.
        .onAppear {
            // withAnimation wraps state changes so SwiftUI animates the transition.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                logoScale = 1.0
                logoOpacity = 1
            }
            // .delay starts this animation slightly after the spring logo pop.
            withAnimation(.easeOut(duration: 0.45).delay(0.12)) {
                titleOpacity = 1
            }
            // repeatForever + autoreverses = continuous pulse of the glow.
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
        // Accessibility: treat children as one element for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance Wizard")
    }
}

/// Hosts main content under a one-shot splash overlay.
struct RootWithSplash: View {
    // true at first paint so the splash is visible; flipped to false after a short delay.
    @State private var showSplash = true

    var body: some View {
        ZStack {
            // Main app UI sits underneath; faded out while splash is showing.
            ContentView()
                .opacity(showSplash ? 0 : 1)

            // if showSplash: only include SplashScreenView in the hierarchy while needed.
            if showSplash {
                SplashScreenView()
                    // transition defines how the view animates when removed.
                    .transition(.opacity)
                    // Higher zIndex draws above ContentView.
                    .zIndex(1)
            }
        }
        // .task starts an async piece of work when the view appears (and cancels if it disappears).
        // async/await: write asynchronous code that looks sequential; await pauses until work finishes.
        .task {
            // Hold long enough to read the brand, short enough not to annoy.
            // try? turns a throwing call into an optional result (nil on failure) — ignore errors here.
            // Task.sleep is non-blocking: the UI stays responsive during the wait.
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            withAnimation(.easeInOut(duration: 0.38)) {
                showSplash = false
            }
        }
    }
}

// #Preview shows this view in Xcode’s canvas without running the full app.
#Preview {
    SplashScreenView()
}
