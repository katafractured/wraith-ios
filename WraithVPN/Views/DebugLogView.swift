// DebugLogView.swift
// WraithVPN
//
// In-app log viewer for founder debug mode. Shows timestamped, categorized
// log entries with copy-to-clipboard and share functionality.

import SwiftUI

struct DebugLogView: View {

    @ObservedObject private var logger = DebugLogger.shared
    @State private var filterCategory: DebugLogCategory? = nil
    @State private var showShareSheet = false
    @State private var copiedToClipboard = false
    @State private var isRunningHealthCheck = false
    @EnvironmentObject var vpn: WireGuardManager

    private var filteredEntries: [DebugLogEntry] {
        guard let cat = filterCategory else { return logger.entries }
        return logger.entries.filter { $0.category == cat }
    }

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterButton(nil, label: "All")
                        filterButton(.api, label: "API")
                        filterButton(.wg, label: "WG")
                        filterButton(.ne, label: "NE")
                        filterButton(.dns, label: "DNS")
                        filterButton(.peer, label: "PEER")
                        filterButton(.app, label: "APP")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color.kfSurface)

                // Log entries
                if filteredEntries.isEmpty {
                    Spacer()
                    Text("No log entries yet.\nInteract with the app to generate logs.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(filteredEntries) { entry in
                                    logRow(entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .onChange(of: logger.entries.count) { _, _ in
                            if let last = filteredEntries.last {
                                withAnimation(.default) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }

                // Action bar
                HStack(spacing: 16) {
                    Button {
                        isRunningHealthCheck = true
                        Task {
                            await runHealthCheck()
                            isRunningHealthCheck = false
                        }
                    } label: {
                        Label(
                            isRunningHealthCheck ? "Testing..." : "DNS Test",
                            systemImage: "network"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .disabled(isRunningHealthCheck)

                    Spacer()

                    Button {
#if canImport(UIKit)
                        UIPasteboard.general.string = logger.exportText
#endif
                        copiedToClipboard = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedToClipboard = false
                        }
                    } label: {
                        Label(
                            copiedToClipboard ? "Copied" : "Copy",
                            systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption.weight(.medium))
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.medium))
                    }

                    Button(role: .destructive) {
                        logger.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.caption.weight(.medium))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.kfSurface)
            }
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = logger.exportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - Subviews

    private func filterButton(_ category: DebugLogCategory?, label: String) -> some View {
        Button {
            filterCategory = category
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filterCategory == category ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(filterCategory == category ? .white : .primary)
                .clipShape(Capsule())
        }
    }

    private func logRow(_ entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(DebugLogger.timestampFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 75, alignment: .leading)

            Text(entry.category.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(categoryColor(entry.category))
                .frame(width: 36, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    private func categoryColor(_ cat: DebugLogCategory) -> Color {
        switch cat {
        case .api:  return .blue
        case .wg:   return .green
        case .ne:   return .kataGold.opacity(0.7)
        case .dns:  return .purple
        case .peer: return .cyan
        case .app:  return .gray
        }
    }

    // MARK: - Health check

    private func runHealthCheck() async {
        // Extract the Haven DNS IP from the current peer's assigned IP.
        // If assigned is 10.10.x.y, Haven DNS is 10.10.x.1.
        let havenIP: String? = {
            guard let assigned = vpn.assignedIP else { return nil }
            let parts = assigned.split(separator: ".")
            guard parts.count == 4 else { return nil }
            return "\(parts[0]).\(parts[1]).\(parts[2]).1"
        }()

        let connection = vpn.tunnelProviderSession
        let report = await DNSHealthCheck.shared.runHealthCheck(
            havenDNSIP: havenIP,
            connection: connection
        )

        DebugLogger.shared.app("Health report: \(report.diagnosis)")
        if report.needsReprovision {
            DebugLogger.shared.app("RECOMMENDATION: Re-provision peer (current peer likely revoked)")
        }
    }
}

// MARK: - Share sheet

#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View {
    let activityItems: [Any]
    var body: some View {
        Text("Share not available on this platform")
    }
}
#endif
