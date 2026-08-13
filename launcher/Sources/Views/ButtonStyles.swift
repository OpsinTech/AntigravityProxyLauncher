import SwiftUI

// MARK: - Standard button modifiers

extension View {
    func primaryActionStyle() -> some View {
        self.buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    func secondaryActionStyle() -> some View {
        self.buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.gray.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    func dangerActionStyle() -> some View {
        self.buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.red.opacity(0.15))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    func successActionStyle() -> some View {
        self.buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .foregroundStyle(.green)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    func iconButtonStyle() -> some View {
        self.buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Unified card style (system colors, adapts to light/dark)

extension View {
    /// A consistent card container used across configuration panels.
    /// Uses semantic system colors so it looks correct in both light and dark mode.
    func cardStyle(accent: Color? = nil, padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent != nil ? AnyShapeStyle(accent!.opacity(0.35)) : AnyShapeStyle(.separator), lineWidth: 1)
            )
    }

    /// A subtle inner panel (e.g. for table rows) using system control background.
    func innerPanelStyle(padding: CGFloat = 10) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AnyShapeStyle(.separator.opacity(0.5)), lineWidth: 1)
            )
    }
}

/// 带图标的按钮标签
struct ButtonLabel: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .bold))
        }
    }
}
