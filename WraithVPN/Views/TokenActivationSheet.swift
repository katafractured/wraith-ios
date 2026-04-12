import SwiftUI

struct TokenActivationSheet: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput    = ""
    @State private var isValidating  = false
    @State private var errorMessage: String? = nil
    @State private var statusMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.kfBackground.ignoresSafeArea()

                VStack(spacing: KFSpacing.lg) {
                    VStack(spacing: KFSpacing.sm) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(Color.kfAccentBlue)

                        Text("Activate with Token")
                            .font(KFFont.heading(22))
                            .foregroundStyle(.white)

                        Text("Enter a coupon or subscription token to unlock the app.")
                            .font(KFFont.body(14))
                            .foregroundStyle(Color.kfTextSecondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: KFSpacing.xs) {
                        TextField("kf_...", text: $tokenInput)
                            .font(KFFont.mono(13))
                            .foregroundStyle(.white)
                            .padding(KFSpacing.md)
                            .background(Color.kfSurface)
                            .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                                    .stroke(errorMessage != nil ? Color.red.opacity(0.6) : Color.kfBorder, lineWidth: 1)
                            )
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit { Task { await activate() } }

                        if let err = errorMessage {
                            Text(err)
                                .font(KFFont.caption(12))
                                .foregroundStyle(.red)
                        }

                        if let msg = statusMessage {
                            Text(msg)
                                .font(KFFont.caption(12))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    }

                    Button {
                        Task { await activate() }
                    } label: {
                        Group {
                            if isValidating {
                                ProgressView().tint(.white)
                            } else {
                                Text("Activate")
                                    .font(KFFont.heading(17))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, KFSpacing.md)
                        .background(LinearGradient.kfAccent)
                        .clipShape(Capsule())
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)

                    Spacer()
                }
                .padding(KFSpacing.lg)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func activate() async {
        let token = tokenInput.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }

        isValidating = true
        errorMessage = nil
        statusMessage = "Validating…"
        defer { isValidating = false }

        do {
            // redeemAccessCode validates, saves all fields (incl. iCloud sync for founders),
            // and calls reloadFromKeychain internally.
            try await storeKit.redeemAccessCode(token)
            statusMessage = nil
            dismiss()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}
