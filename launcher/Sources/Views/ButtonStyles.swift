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
