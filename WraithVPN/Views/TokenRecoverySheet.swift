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
    @State private var identityType = "email"     // "email" | "apple_id"
    @State private var identityValue = ""
    @State private var identityDeliveryEmail = ""
    @State private var identitySuccessMessage: String? = nil

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(KFSpacing.lg)

                Picker("Recovery Method", selection: $selectedTab) {
                    Text("Email Recovery").tag(0)
                    Text("Enter Token").tag(1)
                    Text("By Identity").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, KFSpacing.md)
                .padding(.vertical, KFSpacing.md)

                Divider()
                    .background(Color.kfBorder)

                VStack(spacing: KFSpacing.lg) {
                    if selectedTab == 0 {
                        emailTab
                    } else if selectedTab == 1 {
                        tokenTab
                    } else {
                        identityTab
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

    // MARK: - Identity recovery tab

    private var identityTab: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            Text("Enter the email address or Apple ID you linked to your account. We'll send a recovery link to the delivery email.")
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Identity type picker
            Picker("Identity Type", selection: $identityType) {
                Text("Email").tag("email")
                Text("Apple ID").tag("apple_id")
            }
            .pickerStyle(.segmented)

            // Linked identity value
            TextField(identityType == "email" ? "linked@email.com" : "Apple ID email", text: $identityValue)
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextPrimary)
                .autocapitalization(.none)
                .keyboardType(.emailAddress)
                .padding(KFSpacing.sm)
                .background(Color.kfSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous).stroke(Color.kfBorder, lineWidth: 1))

            // Delivery email
            VStack(alignment: .leading, spacing: 4) {
                Text("Send recovery link to:")
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextMuted)
                TextField("delivery@email.com", text: $identityDeliveryEmail)
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextPrimary)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .padding(KFSpacing.sm)
                    .background(Color.kfSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous).stroke(Color.kfBorder, lineWidth: 1))
            }

            Button {
                Task { await sendIdentityRecovery() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send Recovery Link")
                            .font(KFFont.body(15))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KFSpacing.sm)
                .background(
                    (identityValue.isEmpty || identityDeliveryEmail.isEmpty || isLoading)
                        ? Color.kfAccentBlue.opacity(0.4)
                        : Color.kfAccentBlue
                )
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous))
            }
            .disabled(identityValue.isEmpty || identityDeliveryEmail.isEmpty || isLoading)

            if let msg = identitySuccessMessage {
                Text(msg)
                    .font(KFFont.caption(13))
                    .foregroundStyle(Color.kfConnected)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = errorMessage {
                Text(err)
                    .font(KFFont.caption(13))
                    .foregroundStyle(Color.kfError)
            }

            Text("The recovery link expires in 15 minutes. Paste the kfr_ token from the link into the \"Enter Token\" tab.")
                .font(KFFont.caption(11))
                .foregroundStyle(Color.kfTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(KFSpacing.md)
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

    private func sendIdentityRecovery() async {
        isLoading = true
        errorMessage = nil
        identitySuccessMessage = nil
        defer { isLoading = false }
        do {
            let body = IdentityRecoverBody(
                identityType:  identityType,
                identityValue: identityValue.trimmingCharacters(in: .whitespacesAndNewlines),
                email:         identityDeliveryEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let _ = try await URLSession.shared.data(for: identityRecoverRequest(body))
            identitySuccessMessage = "If your identity is on file, a recovery link has been sent. Check your email."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct IdentityRecoverBody: Encodable {
        let identityType:  String
        let identityValue: String
        let email:         String

        enum CodingKeys: String, CodingKey {
            case identityType  = "identity_type"
            case identityValue = "identity_value"
            case email
        }
    }

    private func identityRecoverRequest(_ body: IdentityRecoverBody) throws -> URLRequest {
        let url = URL(string: "https://api.katafract.com/v1/token/recover/identity")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }
}

#Preview {
    TokenRecoverySheet()
        .environmentObject(StoreKitManager())
}
