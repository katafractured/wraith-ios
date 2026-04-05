// OnboardingView.swift
// WraithVPN
//
// 3-screen onboarding carousel shown on first launch.
// Exits by calling onComplete(), which the root view uses to
// dismiss onboarding and persist the seen flag.

import SwiftUI

// MARK: - Data

private struct OnboardingPage: Identifiable {
    let id: Int
    let eyebrow: String
    let assetName: String
    let title: String
    let body: String
    let accentColor: Color
    let secondaryColor: Color
}

private let pages: [OnboardingPage] = [
    OnboardingPage(
        id: 0,
        eyebrow: "PRIVATE ACCESS",
        assetName: "OnboardingPrivacy",
        title: "Private Traffic.\nClear Boundaries.",
        body: "WraithVPN secures your traffic with modern WireGuard encryption, helping keep your connection private on cellular and Wi-Fi.",
        accentColor: .kfAccentBlue,
        secondaryColor: Color(hex: "#5ea3ff")
    ),
    OnboardingPage(
        id: 1,
        eyebrow: "WRAITHGATES",
        assetName: "OnboardingWraithGate",
        title: "WraithGates.\nFast Entry.",
        body: "Quick connect routes you through the best available WraithGate for your connection, so you can get into the Enclave without manual setup.",
        accentColor: .kfAccentMid,
        secondaryColor: Color(hex: "#8f7bff")
    ),
    OnboardingPage(
        id: 2,
        eyebrow: "ENCLAVE",
        assetName: "OnboardingEnclave",
        title: "Enclave +\nHaven DNS.",
        body: "Inside the Enclave, Haven DNS helps cut down ad and tracker traffic while we keep the product language grounded in what is actually live.",
        accentColor: .kfAccentPurple,
        secondaryColor: Color(hex: "#b68cff")
    ),
]

// MARK: - View

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentPage: Int = 0

    var body: some View {
        GeometryReader { proxy in
            let layout = OnboardingLayout(proxy: proxy)
            let page = pages[currentPage]

            ZStack {
                background(for: page, layout: layout)

                VStack(spacing: 0) {
                    header(for: page, layout: layout)

                    TabView(selection: $currentPage) {
                        ForEach(pages) { page in
                            OnboardingPageView(page: page, layout: layout)
                                .tag(page.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.35), value: currentPage)
                }
            }
            .safeAreaInset(edge: .bottom) {
                controls(layout: layout)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func background(for page: OnboardingPage, layout: OnboardingLayout) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.kfBackground,
                    Color(hex: "#0b0d15"),
                    Color(hex: "#090b11"),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [page.accentColor.opacity(0.18), Color.clear],
                center: .top,
                startRadius: 10,
                endRadius: layout.backgroundGlowRadius
            )
            .offset(y: -40)
            .ignoresSafeArea()

            Circle()
                .fill(page.secondaryColor.opacity(0.06))
                .frame(width: layout.ambientOrbSize, height: layout.ambientOrbSize)
                .blur(radius: layout.ambientBlurRadius)
                .offset(x: layout.ambientOffsetX, y: layout.ambientOffsetY)

            Circle()
                .stroke(page.accentColor.opacity(0.1), lineWidth: 1)
                .frame(width: layout.backgroundRingSize, height: layout.backgroundRingSize)
                .offset(x: layout.backgroundRingOffsetX, y: layout.backgroundRingOffsetY)
        }
    }

    private func header(for page: OnboardingPage, layout: OnboardingLayout) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("WRAITHVPN")
                    .font(KFFont.caption(11, weight: .bold))
                    .kerning(2.6)
                    .foregroundStyle(Color.kfTextMuted)
                Text(page.eyebrow)
                    .font(KFFont.heading(layout.headerTitleSize))
                    .foregroundStyle(.white)
            }

            Spacer()

            Text("\(currentPage + 1) / \(pages.count)")
                .font(KFFont.caption(12, weight: .semibold))
                .foregroundStyle(Color.kfTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.kfSurface.opacity(0.92))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.kfBorder, lineWidth: 1)
                )
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, layout.topPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    private func controls(layout: OnboardingLayout) -> some View {
        VStack(spacing: layout.controlsSpacing) {
            HStack(spacing: KFSpacing.xs) {
                ForEach(pages) { page in
                    Capsule()
                        .fill(currentPage == page.id ? Color.white : Color.white.opacity(0.22))
                        .frame(width: currentPage == page.id ? 28 : 8, height: 8)
                        .animation(.spring(response: 0.35), value: currentPage)
                }
            }

            Button(action: advance) {
                Text(currentPage == pages.count - 1 ? "Get Started" : "Continue")
                    .font(KFFont.heading(18))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, layout.buttonVerticalPadding)
                    .background(LinearGradient.kfAccent)
                    .clipShape(Capsule())
                    .shadow(color: Color.kfAccentPurple.opacity(0.22), radius: 24, y: 12)
            }
            .padding(.horizontal, layout.horizontalPadding)

            Button("Skip") { onComplete() }
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextMuted)
                .opacity(currentPage < pages.count - 1 ? 1 : 0)
                .disabled(currentPage == pages.count - 1)
        }
        .padding(.top, layout.controlsTopPadding)
        .padding(.bottom, layout.bottomPadding)
        .background(
            LinearGradient(
                colors: [Color.kfBackground.opacity(0), Color.kfBackground.opacity(0.88), Color.kfBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func advance() {
        if currentPage < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentPage += 1
            }
        } else {
            onComplete()
        }
    }
}

// MARK: - Single Page

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let layout: OnboardingLayout

    @State private var appeared = false

    var body: some View {
        VStack(spacing: layout.contentSpacing) {
            hero
                .padding(.top, layout.heroTopPadding)

            VStack(spacing: layout.textSpacing) {
                Text(page.title)
                    .font(KFFont.display(layout.titleSize))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.88)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)

                Text(page.body)
                    .font(KFFont.body(layout.bodySize))
                    .foregroundStyle(Color.kfTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(layout.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.92)
                    .frame(maxWidth: layout.bodyWidth)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
            }

            if layout.bottomSpacer > 0 {
                Spacer(minLength: layout.bottomSpacer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, layout.horizontalPadding)
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.78)) {
                appeared = true
            }
        }
        .onDisappear {
            appeared = false
        }
    }

    private var hero: some View {
        ZStack {
            Ellipse()
                .fill(page.accentColor.opacity(0.14))
                .frame(width: layout.heroGlowWidth, height: layout.heroGlowHeight)
                .blur(radius: layout.heroBlurRadius)

            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: layout.heroFrameHeight)
                .overlay(
                    Image(page.assetName)
                        .resizable()
                        .scaledToFill()
                )
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .stroke(page.accentColor.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: page.accentColor.opacity(0.18), radius: 34, y: 18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.heroFrameHeight)
        .scaleEffect(appeared ? 1 : 0.88)
        .opacity(appeared ? 1 : 0)
    }
}

// MARK: - Layout

private struct OnboardingLayout {
    let size: CGSize
    let safeTop: CGFloat
    let safeBottom: CGFloat

    init(proxy: GeometryProxy) {
        size = proxy.size
        safeTop = proxy.safeAreaInsets.top
        safeBottom = proxy.safeAreaInsets.bottom
    }

    private var compactHeight: Bool { size.height < 760 }
    private var expansiveHeight: Bool { size.height > 900 }
    private var isIPad: Bool { size.width > 600 }

    var horizontalPadding: CGFloat { expansiveHeight ? 34 : 28 }
    var topPadding: CGFloat { safeTop + (expansiveHeight ? 18 : 10) }
    var headerBottomPadding: CGFloat { expansiveHeight ? 22 : (compactHeight ? 12 : 18) }
    var headerTitleSize: CGFloat { expansiveHeight ? 26 : (compactHeight ? 22 : 24) }

    var backgroundGlowRadius: CGFloat { expansiveHeight ? 360 : 280 }
    var ambientOrbSize: CGFloat { expansiveHeight ? 320 : 220 }
    var ambientBlurRadius: CGFloat { expansiveHeight ? 80 : 56 }
    var ambientOffsetX: CGFloat { expansiveHeight ? 120 : 84 }
    var ambientOffsetY: CGFloat { expansiveHeight ? 260 : 210 }
    var backgroundRingSize: CGFloat { expansiveHeight ? 340 : 250 }
    var backgroundRingOffsetX: CGFloat { expansiveHeight ? 110 : 90 }
    var backgroundRingOffsetY: CGFloat { expansiveHeight ? -10 : 10 }

    var heroTopPadding: CGFloat { expansiveHeight ? 18 : (compactHeight ? 4 : 10) }
    var heroFrameHeight: CGFloat { isIPad ? 660 : (expansiveHeight ? 480 : (compactHeight ? 280 : 370)) }
    var heroGlowWidth: CGFloat { isIPad ? 580 : (expansiveHeight ? 480 : (compactHeight ? 300 : 390)) }
    var heroGlowHeight: CGFloat { isIPad ? 440 : (expansiveHeight ? 370 : (compactHeight ? 230 : 300)) }
    var heroBlurRadius: CGFloat { expansiveHeight ? 44 : 30 }
    var titleSize: CGFloat { expansiveHeight ? 44 : (compactHeight ? 31 : 35) }
    var bodySize: CGFloat { expansiveHeight ? 18 : (compactHeight ? 15 : 16) }
    var bodyLineSpacing: CGFloat { expansiveHeight ? 5 : (compactHeight ? 3 : 4) }
    var bodyWidth: CGFloat { min(size.width - (horizontalPadding * 2), isIPad ? 560 : (expansiveHeight ? 360 : 320)) }

    var contentSpacing: CGFloat { expansiveHeight ? 26 : (compactHeight ? 16 : 22) }
    var textSpacing: CGFloat { expansiveHeight ? 18 : (compactHeight ? 12 : 16) }
    var bottomSpacer: CGFloat { isIPad ? 0 : (expansiveHeight ? 20 : (compactHeight ? 4 : 8)) }

    var controlsSpacing: CGFloat { expansiveHeight ? 20 : (compactHeight ? 14 : 18) }
    var controlsTopPadding: CGFloat { expansiveHeight ? 28 : (compactHeight ? 16 : 22) }
    var buttonVerticalPadding: CGFloat { expansiveHeight ? 19 : (compactHeight ? 15 : 17) }
    var bottomPadding: CGFloat { max(safeBottom, 14) + (expansiveHeight ? 16 : 10) }
}

// MARK: - Preview

#Preview {
    OnboardingView { }
}
