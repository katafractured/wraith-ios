import SwiftUI

struct TokenEntryView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput      = ""
    @State private var isValidating    = false
    @State private var validationError: String? = nil
    @State private var statusMessage: String? = nil

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
                ScrollView {
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 80)
                .padding(8)
                .background(Color.red.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
        .frame(minWidth: 340, maxWidth: 520)
        .onAppear {
            // Bring window to front and keep it above other windows
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.title == "Activate Wraith" })?.level = .floating
            }
        }
    }

    private func validate() async {
        let token = tokenInput.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }

        isValidating = true
        validationError = nil
        statusMessage = nil
        defer { isValidating = false }

        do {
            // 1. Validate token
            statusMessage = "Validating token…"
            let info = try await APIClient.shared.validateToken(token)
            try KeychainHelper.shared.save(token,     for: .subscriptionToken)
            try KeychainHelper.shared.save(info.plan, for: .tokenPlan)
            if let exp = info.expiresAt {
                try KeychainHelper.shared.save(exp, for: .tokenExpiresAt)
            }

            // 2. Provision a peer for this Mac
            statusMessage = "Provisioning VPN peer…"
            let provision = try await APIClient.shared.provisionPeer(
                pubkey: "",
                regionId: nil,
                label:  "Mac — \(Host.current().localizedName ?? "Desktop")"
            )
            try VPNConfigManager.shared.store(response: provision)

            await storeKit.reloadFromKeychain()
            statusMessage = nil
            dismiss()
        } catch {
            statusMessage = nil
            validationError = error.localizedDescription
        }
    }
}
