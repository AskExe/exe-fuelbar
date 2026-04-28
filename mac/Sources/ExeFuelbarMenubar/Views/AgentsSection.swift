import SwiftUI

// MARK: - AI Employees (parent section)

/// Parent section for exe-os agent data. Contains two collapsible sub-sections:
/// "Memory" (per-agent memory count + growth) and "Spend" (per-agent cost).
struct AgentsSection: View {
    @Environment(AppStore.self) private var store
    @State private var isExpanded: Bool = true

    var body: some View {
        if let stats = store.payload.agentStats {
            CollapsibleSection(
                caption: "AI Employees",
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 0) {
                    MemorySubSection(stats: stats)
                    Divider().opacity(0.3).padding(.vertical, 6)
                    SpendSubSection(stats: stats)
                }
            }
        }
    }
}

// MARK: - Memory sub-section

private struct MemorySubSection: View {
    let stats: AgentStatsBlock

    private let colMem: CGFloat = 46
    private let colGrowth: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Sub-header
            HStack(spacing: 3) {
                Text("Memory")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.brandAccent.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Mem").frame(width: colMem, alignment: .trailing)
                Text("24h").frame(width: colGrowth, alignment: .trailing)
                Text("7d").frame(width: colGrowth, alignment: .trailing)
                Text("30d").frame(width: colGrowth, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .tracking(-0.05)

            let maxTotal = stats.agents.map(\.total).max() ?? 1
            ForEach(stats.agents.prefix(8)) { agent in
                MemoryRow(agent: agent, maxTotal: maxTotal,
                          colMem: colMem, colGrowth: colGrowth)
            }
        }
    }
}

private struct MemoryRow: View {
    let agent: AgentStat
    let maxTotal: Int
    let colMem: CGFloat
    let colGrowth: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            FixedBar(fraction: Double(agent.total) / Double(maxTotal))
                .frame(width: 32, height: 6)

            Text(agent.id)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            Text(agent.total.asThousandsSeparated())
                .font(.codeMono(size: 10.5, weight: .medium))
                .tracking(-0.3)
                .monospacedDigit()
                .frame(width: colMem, alignment: .trailing)

            GrowthCell(value: agent.growth24h)
                .frame(width: colGrowth, alignment: .trailing)

            GrowthCell(value: agent.growth7d)
                .frame(width: colGrowth, alignment: .trailing)

            GrowthCell(value: agent.growth30d)
                .frame(width: colGrowth, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }
}

// MARK: - Spend sub-section

private struct SpendSubSection: View {
    let stats: AgentStatsBlock

    private let colSpend: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Sub-header
            HStack(spacing: 3) {
                Text("Employee Spend")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.brandAccent.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("24h").frame(width: colSpend, alignment: .trailing)
                Text("7d").frame(width: colSpend, alignment: .trailing)
                Text("30d").frame(width: colSpend, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .tracking(-0.05)

            let sorted = stats.agents
                .filter { $0.cost30d > 0 }
                .sorted { $0.cost30d > $1.cost30d }

            if sorted.isEmpty {
                Text("No agent spend recorded yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                let maxCost = sorted.first?.cost30d ?? 1
                ForEach(sorted.prefix(8)) { agent in
                    SpendRow(agent: agent, maxCost: maxCost, colSpend: colSpend)
                }
            }
        }
    }
}

private struct SpendRow: View {
    let agent: AgentStat
    let maxCost: Double
    let colSpend: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            FixedBar(fraction: agent.cost30d / maxCost)
                .frame(width: 32, height: 6)

            Text(agent.id)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            SpendCell(value: agent.cost24h)
                .frame(width: colSpend, alignment: .trailing)

            SpendCell(value: agent.cost7d)
                .frame(width: colSpend, alignment: .trailing)

            SpendCell(value: agent.cost30d)
                .frame(width: colSpend, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }
}

/// Compact cost cell — shows $X.XX or dash when zero.
private struct SpendCell: View {
    let value: Double

    var body: some View {
        Text(text)
            .font(.codeMono(size: 10, weight: .medium))
            .tracking(-0.2)
            .monospacedDigit()
            .foregroundStyle(value > 0 ? .primary : .secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var text: String {
        if value <= 0 { return "—" }
        return value.asCompactCurrency()
    }
}

// MARK: - Shared

/// Tiny +N cell — green when positive, muted dash when zero.
private struct GrowthCell: View {
    let value: Int

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var text: String {
        if value == 0 { return "—" }
        return "+\(value.asThousandsSeparated())"
    }

    private var color: Color {
        value > 0 ? Theme.oneShotGood : .secondary
    }
}
