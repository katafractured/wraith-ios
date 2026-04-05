import SwiftUI

struct TokenEntryView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput      = ""
    @State private var isValidating    = false
    @State private var validationError: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("Activate WraithVPN")
                .font(.headline)

            Text("Paste your token from connect.katafract.com, or a token copied from your iOS device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Paste token here", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { Task { await validate() } }

            if let err = validationError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }

                Spacer()

                Button("Restore iOS Purchase") {
                    Task {
                        await storeKit.restorePurchases()
                        if storeKit.hasPurchased { dismiss() }
                    }
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await validate() }
                } label: {
                    if isValidating {
                        ProgressView().scaleEffect(0.8).frame(width: 60)
                    } else {
                        Text("Activate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
            }

            if !storeKit.products.isEmpty {
                Divider()
                Text("Or subscribe directly:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(storeKit.products, id: \.id) { product in
                    Button {
                        Task {
                            await storeKit.purchase(product)
                            if storeKit.hasPurchased { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text(product.displayName).font(.system(size: 11))
                            Spacer()
                            Text(product.displayPrice).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func validate() async {
        let token = tokenInput.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }

        isValidating = true
        validationError = nil
        defer { isValidating = false }

        do {
            let info = try await APIClient.shared.validateToken(token)
            try KeychainHelper.shared.save(token,          for: .subscriptionToken)
            try KeychainHelper.shared.save(info.expiresAt, for: .tokenExpiresAt)
            try KeychainHelper.shared.save(info.plan,      for: .tokenPlan)
            await storeKit.restorePurchases()
            dismiss()
        } catch {
            validationError = "Invalid token: \(error.localizedDescription)"
        }
    }
}
