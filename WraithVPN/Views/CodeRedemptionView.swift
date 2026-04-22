// CodeRedemptionView.swift
// WraithVPN
//
// Hidden tap-to-redeem flow: Apple Offer Code redemption + account restore via sign-in.
// Compliant with Apple Guideline 3.1.1 (reviewer test access).

import SwiftUI
import StoreKit
import KatafractStyle

struct CodeRedemptionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showRedemption = false
    @State private var showSignIn = false
    @State private var redemptionStatus: String? = nil
    @State private var showStatusAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.kataGold)
                    .padding(.top, 40)

                Text("Have a code?")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Founders, family, and App Review can redeem an Apple Offer Code or sign in to restore an existing subscription.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 12) {
                    Button(action: { showRedemption = true }) {
                        Text("Redeem Offer Code")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.kataGold)
                            .foregroundStyle(.black)
                            .font(.system(size: 16, weight: .semibold))
                            .cornerRadius(8)
                    }

                    Button(action: { showSignIn = true }) {
                        Text("Sign in to restore")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.kfSurface.opacity(0.7))
                            .foregroundStyle(.white)
                            .font(.system(size: 16, weight: .semibold))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                Text("Apple Guideline 3.1.1 compliant.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 16)
            }
            .padding()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.kataGold)
                }
            }
            .preferredColorScheme(.dark)
            .offerCodeRedemption(isPresented: $showRedemption) { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        redemptionStatus = "Offer code redeemed successfully!"
                        showStatusAlert = true
                        KataHaptic.unlocked.fire()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    case .failure(let err):
                        redemptionStatus = "Redemption failed: \(err.localizedDescription)"
                        showStatusAlert = true
                        print("[CodeRedemption] error: \(err)")
                    }
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInRestoreView()
                    .presentationDetents([.medium, .large])
            }
            .alert("Redemption Status", isPresented: $showStatusAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(redemptionStatus ?? "Unknown status")
            }
        }
    }
}

// MARK: - Sign In Restore View

struct SignInRestoreView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Sign In to Restore")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()

                Text("Sign in with your Katafract account to restore an existing Enclave or Sovereign subscription on this device.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    Button(action: handleSignIn) {
                        if isLoading {
                            ProgressView()
                                .tint(Color.kataGold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        } else {
                            Text("Sign In with Katafract")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.kataGold)
                                .foregroundStyle(.black)
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .disabled(isLoading)
                }
                .padding()

                Spacer()

                Text("You'll be redirected to the Katafract auth portal.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.kataGold)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func handleSignIn() {
        isLoading = true
        // TODO(christian): Wire to existing AuthService.signIn() or new Sigil restore flow.
        // For now, this is a stub that dismisses after simulating network delay.
        Task {
            try? await Task.sleep(for: .seconds(1))
            isLoading = false
            dismiss()
        }
    }
}

#Preview {
    CodeRedemptionView()
        .preferredColorScheme(.dark)
}
