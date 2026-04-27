import SwiftUI

/// Shows exe-os agent memory stats when exe-os is detected (agentStats != nil).
/// Displays per-agent memory count with gold bars and 7-day growth.
struct AgentsSection: View {
    @Environment(AppStore.self) private var store
    @State private var isExpanded: Bool = true

    var body: some View {
        if let stats = store.payload.agentStats {
            CollapsibleSection(
                caption: "Agents",
                isExpanded: $isExpanded,
                trailing: {
                    HStack(spacing: 8) {
                        Text("Memories").frame(minWidth: 64, alignment: .trailing)
                        Text("7d").frame(minWidth: 36, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .tracking(-0.05)
                }
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    let maxTotal = stats.agents.map(\.total).max() ?? 1
                    ForEach(stats.agents.prefix(8)) { agent in
                        AgentRow(agent: agent, maxTotal: maxTotal)
                    }
                }
            }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentStat
    let maxTotal: Int

    var body: some View {
        HStack(spacing: 8) {
            FixedBar(fraction: Double(agent.total) / Double(maxTotal))
                .frame(width: 56, height: 6)

            Text(agent.id)
                .font(.system(size: 12.5, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(agent.total.asThousandsSeparated())
                .font(.codeMono(size: 12, weight: .medium))
                .tracking(-0.2)
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)

            Text(growthText)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(growthColor)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }

    private var growthText: String {
        if agent.growth7d == 0 { return "—" }
        return "+\(agent.growth7d)"
    }

    private var growthColor: Color {
        if agent.growth7d > 0 { return Theme.oneShotGood }
        return .secondary
    }
}
