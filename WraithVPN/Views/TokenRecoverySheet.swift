// TokenRecoverySheet.swift
// WraithVPN
//
// Three recovery paths presented as a single scrollable view:
//   1. App Store restore (StoreKit)
//   2. Email recovery link (Stripe email or registered identity)
//   3. Paste token directly (kf_ or kfr_)

import SwiftUI

struct TokenRecoverySheet: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var emailText            = ""
    @State private var tokenText            = ""
    @State private var isLoadingEmail       = false
    @State private var isLoadingToken       = false
    @State private var isRestoringPurchase  = false
    @State private var emailError:          String? = nil
    @State private var emailSuccess:        String? = nil
    @State private var tokenError:          String? = nil

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: KFSpacing.xl) {
                    header
                    privacyBanner
                    appStoreMethod
                    Divider().background(Color.kfBorder)
                    emailMethod
                    Divider().background(Color.kfBorder)
                    tokenMethod
                    footerNote
                }
                .padding(KFSpacing.lg)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: KFSpacing.xs) {
                Text("Recover Access")
                    .font(KFFont.heading(22))
                    .foregroundStyle(.white)
                Text("Get back in on a new device.")
                    .font(KFFont.caption(13))
                    .foregroundStyle(Color.kfTextSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.kfAccentBlue)
            }
        }
    }

    // MARK: - Privacy banner

    private var privacyBanner: some View {
        HStack(alignment: .top, spacing: KFSpacing.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.kfAccentBlue)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your email is never required.")
                    .font(KFFont.body(13))
                    .foregroundStyle(.white)
                Text("If you didn't register one, recovery is still available via App Store restore or your original token. Register an email in Settings → Security to enable email recovery.")
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(KFSpacing.md)
        .background(Color.kfAccentBlue.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .stroke(Color.kfAccentBlue.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
    }

    // MARK: - Method 1: App Store

    private var appStoreMethod: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            methodLabel(
                icon: "bag.fill",
                title: "App Store Subscription",
                description: "Subscribed through Apple? Restore your purchase directly — no email or token needed."
            )

            Button {
                Task {
                    isRestoringPurchase = true
                    await storeKit.restorePurchases()
                    isRestoringPurchase = false
                    dismiss()
                }
            } label: {
                Group {
                    if isRestoringPurchase {
                        ProgressView().tint(.white)
                    } else {
                        Text("Restore Purchase")
                            .font(KFFont.heading(15))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KFSpacing.md)
                .background(LinearGradient.kfAccent)
                .clipShape(Capsule())
            }
            .disabled(isRestoringPurchase)
        }
    }

    // MARK: - Method 2: Email recovery

    private var emailMethod: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            methodLabel(
                icon: "envelope.fill",
                title: "Email Recovery",
                description: "Enter the email on your Stripe purchase, or the email you registered as your recovery address. We'll send a one-time link — expires in 15 minutes."
            )

            TextField("your@email.com", text: $emailText)
                .font(KFFont.body(14))
                .foregroundStyle(.white)
                .padding(KFSpacing.sm)
                .background(Color.kfSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                        .stroke(Color.kfBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if let error = emailError {
                Text(error)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfError)
            }
            if let success = emailSuccess {
                Text(success)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfConnected)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await sendEmailRecovery() }
            } label: {
                Group {
                    if isLoadingEmail {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send Recovery Link")
                            .font(KFFont.heading(15))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KFSpacing.md)
                .background(LinearGradient.kfAccent)
                .clipShape(Capsule())
            }
            .disabled(emailText.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingEmail)
        }
    }

    // MARK: - Method 3: Token entry

    private var tokenMethod: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            methodLabel(
                icon: "key.fill",
                title: "Paste Your Token",
                description: "Have your subscription token (kf_…) or a recovery token from a link (kfr_…)? Paste it to restore access immediately — no email needed."
            )

            TextEditor(text: $tokenText)
                .font(KFFont.mono(13))
                .foregroundStyle(.white)
                .padding(KFSpacing.sm)
                .background(Color.kfSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                        .stroke(Color.kfBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                .frame(height: 80)
                .scrollContentBackground(.hidden)

            if let error = tokenError {
                Text(error)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfError)
            }

            Button {
                Task { await activateToken() }
            } label: {
                Group {
                    if isLoadingToken {
                        ProgressView().tint(.white)
                    } else {
                        Text("Activate Token")
                            .font(KFFont.heading(15))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KFSpacing.md)
                .background(LinearGradient.kfAccent)
                .clipShape(Capsule())
            }
            .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingToken)
        }
    }

    // MARK: - Footer note

    private var footerNote: some View {
        Text("Wraith never stores passwords. Your token is your key — keep a copy somewhere safe if you didn't register a recovery email.")
            .font(KFFont.caption(11))
            .foregroundStyle(Color.kfTextMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .lineSpacing(3)
            .padding(.bottom, KFSpacing.lg)
    }

    // MARK: - Shared label

    private func methodLabel(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.kfAccentBlue)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(KFFont.heading(15))
                    .foregroundStyle(.white)
                Text(description)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: - Actions

    private func sendEmailRecovery() async {
        let email = emailText.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }
        isLoadingEmail = true
        emailError = nil
        emailSuccess = nil
        defer { isLoadingEmail = false }
        do {
            _ = try await APIClient.shared.recoverByEmail(email)
            emailSuccess = "Check your inbox for a recovery link. It expires in 15 minutes — paste the kfr_ token from it into the token field above."
            emailText = ""
        } catch {
            emailError = error.localizedDescription
        }
    }

    private func activateToken() async {
        let token = tokenText.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        isLoadingToken = true
        tokenError = nil
        defer { isLoadingToken = false }
        do {
            let resp: TokenResponse
            if token.hasPrefix("kfr_") {
                resp = try await APIClient.shared.redeemRecoveryToken(token)
            } else {
                let info = try await APIClient.shared.validateToken(token)
                resp = TokenResponse(token: token, expiresAt: info.expiresAt ?? "", plan: info.plan)
                try? KeychainHelper.shared.save(info.isAdmin ? "1" : "0", for: .tokenIsAdmin)
            }
            try? KeychainHelper.shared.save(resp.token,     for: .subscriptionToken)
            try? KeychainHelper.shared.save(resp.expiresAt, for: .tokenExpiresAt)
            try? KeychainHelper.shared.save(resp.plan,      for: .tokenPlan)
            await storeKit.reloadFromKeychain()
            dismiss()
        } catch {
            tokenError = error.localizedDescription
        }
    }
}

#Preview {
    TokenRecoverySheet()
        .environmentObject(StoreKitManager())
}
