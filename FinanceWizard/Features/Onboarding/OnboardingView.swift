//
//  OnboardingView.swift
//  Finance Wizard
//
//  First-run Welcome after splash. No painted background (Light/Dark is the canvas).
//  Starts as the same centered app icon as SplashScreenView, then the icon lifts
//  and the feature list + Get Started appear. Get Started sets onboarding completed.
//  Uses AppIconImage (imageset), not Image("AppIcon").
//

import SwiftUI

struct OnboardingView: View {
    @State private var isLifted = false
    @AppStorage(OnboardingStore.storageKey) private var hasCompleted = false

    var body: some View {
        VStack(spacing: 0) {
            if !isLifted {
                Spacer()
            }

            let iconSize: CGFloat = isLifted ? 96 : 256
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2237, style: .continuous))
                .shadow(color: .black.opacity(isLifted ? 0.30 : 0.20), radius: isLifted ? 10 : 20, y: isLifted ? 6 : 10)
                .padding(.top, isLifted ? 80 : 0)

            if isLifted {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Welcome")
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                    HStack(alignment: .top, spacing: 20) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("All your charges")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Link your banks. Search, filter by month, and recategorize anything that’s wrong.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(alignment: .top, spacing: 20) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cards and accounts")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Credit, checking, and savings together — balances, utilization, and bills coming due.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(alignment: .top, spacing: 20) {
                        Image(systemName: "chart.pie.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Monthly budget")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Set an overall cap and category limits. Remaining updates as real charges come in.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 48)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Button {
                    hasCompleted = true
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                // AccentColor is ink (dark in Light, light in Dark). borderedProminent
                // often keeps a light label, which vanishes on the Dark fill. Canvas
                // color contrasts both schemes; .colorInvert() only “fixes” one.
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 40)
                .padding(.bottom, 8)
            } else {
                Spacer()
            }
        }

        .task {
            // Hold the centered icon until SplashScreenView has faded (~1.35s + 0.38s).
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeInOut(duration: 0.55)) {
                isLifted = true
            }
        }
    }
}

#Preview {
    OnboardingView()
}
