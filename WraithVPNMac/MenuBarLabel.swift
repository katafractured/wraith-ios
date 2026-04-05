import SwiftUI

struct MenuBarStatusRow: View {
    let isActive: Bool
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
}
