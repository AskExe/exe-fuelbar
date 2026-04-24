import SwiftUI

struct PeriodSegmentedControl: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Period.allCases) { period in
                Button {
                    Task { await store.switchTo(period: period) }
                } label: {
                    Text(period.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.selectedPeriod == period ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(store.selectedPeriod == period ? Color(NSColor.windowBackgroundColor).opacity(0.85) : .clear)
                        .shadow(color: .black.opacity(store.selectedPeriod == period ? 0.06 : 0), radius: 1, y: 0.5)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}
