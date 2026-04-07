// TokenRecoverySheet.swift
// WraithVPN
//
// Two-path token recovery: email-based recovery (Stripe subscribers)
// or direct recovery token entry (kfr_* tokens from recovery emails).

import SwiftUI

struct TokenRecoverySheet: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0   // 0 = Email, 1 = Token
    @State private var emailText = ""
    @State private var tokenText = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(KFSpacing.lg)

                Picker("Recovery method", selection: $selectedTab) {
                    Text("Email Recovery").tag(0)
                    Text("Enter Token").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, KFSpacing.lg)
                .padding(.vertical, KFSpacing.md)

                Divider()
                    .background(Color.kfBorder)

                VStack(spacing: KFSpacing.lg) {
                    if selectedTab == 0 {
                        emailTab
                    } else {
                        tokenTab
                    }

                    Spacer()
                }
                .padding(KFSpacing.lg)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: KFSpacing.xs) {
            HStack {
                Text("Recover Access")
                    .font(KFFont.heading(20))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }

            Text("Restore your subscription on a new device.")
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfTextSecondary)
        }
    }

    // MARK: - Email recovery tab

    private var emailTab: some View {
        VStack(spacing: KFSpacing.lg) {
            VStack(alignment: .leading, spacing: KFSpacing.md) {
                Text("Enter the email address used with your Stripe purchase. We'll send a recovery link.")
                    .font(KFFont.body(13))
                    .foregroundStyle(Color.kfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                if let error = errorMessage {
                    Text(error)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfError)
                }

                if let success = successMessage {
                    Text(success)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfConnected)
                }
            }

            Button {
                Task { await emailRecovery() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send Recovery Email")
                            .font(KFFont.heading(15))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KFSpacing.md)
                .background(LinearGradient.kfAccent)
                .clipShape(Capsule())
            }
            .disabled(emailText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)

            Spacer()
        }
    }

    // MARK: - Token recovery tab

    private var tokenTab: some View {
        VStack(spacing: KFSpacing.lg) {
            VStack(alignment: .leading, spacing: KFSpacing.md) {
                Text("Paste your subscription token or recovery token (starts with kfr_).")
                    .font(KFFont.body(13))
                    .foregroundStyle(Color.kfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                if let error = errorMessage {
                    Text(error)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfError)
                }

                if let success = successMessage {
                    Text(success)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfConnected)
                }
            }

            Button {
                Task { await tokenRecovery() }
            } label: {
                Group {
                    if isLoading {
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
            .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)

            Spacer()
        }
    }

    // MARK: - Recovery actions

    private func emailRecovery() async {
        let email = emailText.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { isLoading = false }

        do {
            _ = try await APIClient.shared.recoverByEmail(email)
            successMessage = "Check your email for a recovery link. It expires in 15 minutes."
            emailText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func tokenRecovery() async {
        let token = tokenText.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { isLoading = false }

        do {
            let resp: TokenResponse
            if token.hasPrefix("kfr_") {
                resp = try await APIClient.shared.redeemRecoveryToken(token)
            } else {
                let info = try await APIClient.shared.validateToken(token)
                resp = TokenResponse(token: token, expiresAt: info.expiresAt ?? "", plan: info.plan)
            }
            await persistAndActivate(resp)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistAndActivate(_ resp: TokenResponse) async {
        try? KeychainHelper.shared.save(resp.token, for: .subscriptionToken)
        try? KeychainHelper.shared.save(resp.expiresAt, for: .tokenExpiresAt)
        try? KeychainHelper.shared.save(resp.plan, for: .tokenPlan)
        await storeKit.reloadFromKeychain()
        dismiss()
    }
}

#Preview {
    TokenRecoverySheet()
        .environmentObject(StoreKitManager())
}
