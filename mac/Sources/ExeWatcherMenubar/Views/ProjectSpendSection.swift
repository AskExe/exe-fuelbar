import SwiftUI

/// Shows per-project spend breakdown with 24h/7d/30d columns.
struct ProjectSpendSection: View {
    @Environment(AppStore.self) private var store
    @State private var isExpanded: Bool = true

    private let colSpend: CGFloat = 52

    var body: some View {
        if let projects = store.payload.projectSpend, !projects.isEmpty {
            CollapsibleSection(
                caption: "Project Spend",
                isExpanded: $isExpanded,
                trailing: {
                    HStack(spacing: 3) {
                        Text("24h").frame(width: colSpend, alignment: .trailing)
                        Text("7d").frame(width: colSpend, alignment: .trailing)
                        Text("30d").frame(width: colSpend, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .tracking(-0.05)
                }
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    let maxCost = projects.first?.cost30d ?? 1
                    ForEach(projects.prefix(10)) { project in
                        ProjectRow(project: project, maxCost: maxCost, colSpend: colSpend)
                    }
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSpendEntry
    let maxCost: Double
    let colSpend: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            FixedBar(fraction: project.cost30d / maxCost)
                .frame(width: 32, height: 6)

            Text(project.name)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            ProjectCostCell(value: project.cost24h)
                .frame(width: colSpend, alignment: .trailing)

            ProjectCostCell(value: project.cost7d)
                .frame(width: colSpend, alignment: .trailing)

            ProjectCostCell(value: project.cost30d)
                .frame(width: colSpend, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }
}

private struct ProjectCostCell: View {
    let value: Double

    var body: some View {
        Text(value > 0 ? value.asCompactCurrencyWhole() : "—")
            .font(.codeMono(size: 10, weight: .medium))
            .tracking(-0.2)
            .monospacedDigit()
            .foregroundStyle(value > 0 ? .primary : .secondary)
            .lineLimit(1)
            .fixedSize()
    }
}
