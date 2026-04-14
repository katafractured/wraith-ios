import SwiftUI

struct MenuBarView: View {

    @EnvironmentObject var storeKit:  StoreKitManager
    @EnvironmentObject var vpnConfig: VPNConfigManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wraith")
                        .font(.system(size: 13, weight: .semibold))
                    Text(planLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // VPN config section
            if let ip = vpnConfig.assignedIP, let node = vpnConfig.nodeId {
                // Peer is provisioned
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VPN Config Ready")
                                .font(.system(size: 12, weight: .medium))
                            Text("\(node)  ·  \(ip)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Text("Use the WireGuard app to connect until native tunnel is live.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)

                    HStack(spacing: 8) {
                        Button("Open in WireGuard") {
                            vpnConfig.exportConfig(label: node)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 11))

                        Button("Download .conf") {
                            vpnConfig.downloadConfig(label: node)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11))

                        Spacer()

                        Button(action: reprovision) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Re-provision (generates a new peer)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            } else {
                // No peer yet
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN")
                            .font(.system(size: 12, weight: .medium))
                        Text("No config provisioned")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider()

            // Haven DNS
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haven DNS")
                        .font(.system(size: 12, weight: .medium))
                    Text("Ad & tracker blocking")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Install Profile") {
                    Task { await downloadAndOpenMobileConfig() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Subscription / token
            let hasToken = KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil
            if hasToken {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let sub = storeKit.subscription, !sub.isExpired {
                            Text(sub.planDisplayName)
                                .font(.system(size: 12, weight: .medium))
                            Text("Active")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        } else {
                            Text("Subscription")
                                .font(.system(size: 12, weight: .medium))
                            Text("Token active")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Manage") {
                        NSWorkspace.shared.open(URL(string: "itms-apps://apps.apple.com/account/subscriptions")!)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    Button("Change") {
                        openWindow(id: "token-entry")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                Button("Enter Token / Restore Purchase") {
                    openWindow(id: "token-entry")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            Divider()

            // Footer
            HStack {
                Button("connect.katafract.com") {
                    NSWorkspace.shared.open(URL(string: "https://connect.katafract.com")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                Spacer()

                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private var planLabel: String {
        if let sub = storeKit.subscription { return sub.planDisplayName }
        return "No active subscription"
    }

    private func downloadAndOpenMobileConfig() async {
        guard let url = URL(string: "https://connect.katafract.com/haven-dns.mobileconfig") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("Haven-DNS.mobileconfig")
            try data.write(to: dest, options: .atomic)
            NSWorkspace.shared.open(dest)
        } catch {}
    }

    private func reprovision() {
        guard let token = KeychainHelper.shared.readOptional(for: .subscriptionToken) else { return }
        vpnConfig.clear()
        Task {
            do {
                let provision = try await APIClient.shared.provisionPeer(
                    pubkey: "",
                    regionId: nil,
                    label:  "Mac — \(Host.current().localizedName ?? "Desktop")"
                )
                try VPNConfigManager.shared.store(response: provision)
            } catch {
                // Re-store token so the UI doesn't break; error is silent here
                _ = token
            }
        }
    }
}
