import SwiftUI

struct MenuBarView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var haven:    HavenDNSManager
    @State private var showTokenEntry = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WraithVPN")
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

            // Haven DNS toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haven DNS")
                        .font(.system(size: 12, weight: .medium))
                    Text("Ad & tracker blocking")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if haven.isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Toggle("", isOn: Binding(
                        get: { haven.isEnabled },
                        set: { _ in Task { await haven.toggle() } }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let err = haven.error {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            Divider()

            // Subscription / token
            if let sub = storeKit.subscription, !sub.isExpired {
                HStack {
                    MenuBarStatusRow(isActive: true, label: sub.planDisplayName)
                    Spacer()
                    Text("Active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                Button("Enter Token / Restore Purchase") {
                    showTokenEntry = true
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
        .frame(width: 260)
        .sheet(isPresented: $showTokenEntry) {
            TokenEntryView()
                .environmentObject(storeKit)
        }
        .task { await haven.refreshStatus() }
    }

    private var planLabel: String {
        if let sub = storeKit.subscription { return sub.planDisplayName }
        return "No active subscription"
    }
}
