import SwiftUI

struct SegmentedQuotaIndicator: View {
    let percentage: Double
    let isExhausted: Bool
    
    var blockWidth: CGFloat = 10
    var blockHeight: CGFloat = 6
    var spacing: CGFloat = 2

    private let totalBlocks = 5
    
    /// Calculates the number of lit blocks based on:
    /// - 0% -> 0 blocks
    /// - 1% - 20% -> 1 block
    /// - 21% - 40% -> 2 blocks
    /// - 41% - 60% -> 3 blocks
    /// - 61% - 80% -> 4 blocks
    /// - 81% - 100% -> 5 blocks
    private var activeBlocksCount: Int {
        if isExhausted || percentage <= 0 {
            return 0
        }
        return min(totalBlocks, Int(ceil(percentage / 20.0)))
    }
    
    /// Determines the color of the active blocks based on remaining percentage
    private var statusColor: Color {
        if percentage < 20 {
            return .red
        } else if percentage < 50 {
            return .orange
        } else {
            return .green
        }
    }
    
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<totalBlocks, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < activeBlocksCount ? statusColor : Color.gray.opacity(0.18))
                    .frame(width: blockWidth, height: blockHeight)
            }
        }
    }
}
