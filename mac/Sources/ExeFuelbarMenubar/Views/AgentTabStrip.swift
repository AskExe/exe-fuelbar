import SwiftUI

struct AgentTabStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(visibleFilters) { filter in
                    Button {
                        Task { await store.switchTo(provider: filter) }
                    } label: {
                        AgentTab(
                            filter: filter,
                            cost: cost(for: filter),
                            isActive: store.selectedProvider == filter
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    /// Drive tab visibility and per-tab cost labels from the *all-provider* payload (today),
    /// not the currently selected provider's payload. Without this, switching to Codex (which
    /// has no data) would hide every other tab including Claude.
    private var allProvidersToday: MenubarPayload {
        store.todayPayload ?? store.payload
    }

    private var visibleFilters: [ProviderFilter] {
        // Only show providers that have actual spend (cost > 0). Providers that are merely
        // "installed" (CLI found credential files) but never used just add clutter.
        let activeKeys = Set(
            allProvidersToday.current.providers
                .filter { $0.value > 0 }
                .keys.map { $0.lowercased() }
        )
        let tabs = ProviderFilter.allCases.filter { filter in
            if filter == .all { return true }
            return activeKeys.contains(filter.rawValue.lowercased())
        }
        // If only .all remains (no provider has spend), show just .all without tabs
        return tabs.count > 1 ? tabs : []
    }

    private func cost(for filter: ProviderFilter) -> Double? {
        switch filter {
        case .all:
            return allProvidersToday.current.cost
        default:
            let key = filter.rawValue.lowercased()
            return allProvidersToday.current.providers[key]
        }
    }
}

private struct AgentTab: View {
    let filter: ProviderFilter
    let cost: Double?
    let isActive: Bool

    /// Dark purple for text on gold backgrounds — darker than brandEmberDeep for better contrast.
    private static let activeTextColor = Color(red: 0x3A/255.0, green: 0x28/255.0, blue: 0x5C/255.0)

    var body: some View {
        HStack(spacing: 5) {
            Text(filter.rawValue)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(-0.05)
                .foregroundStyle(isActive ? Self.activeTextColor : .secondary)
            if let cost, cost > 0 {
                Text(cost.asCompactCurrency())
                    .font(.codeMono(size: 10.5, weight: .medium))
                    .foregroundStyle(isActive ? Self.activeTextColor : .secondary)
                    .tracking(-0.2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AnyShapeStyle(Theme.brandAccent) : AnyShapeStyle(Color.secondary.opacity(0.08)))
        )
        .contentShape(Rectangle())
    }
}

extension ProviderFilter {
    var color: Color {
        switch self {
        case .all: return Theme.brandAccent
        case .claude: return Theme.categoricalClaude
        case .codex: return Theme.categoricalCodex
        case .cursor: return Theme.categoricalCursor
        case .copilot: return Color(red: 0x6D/255.0, green: 0x8F/255.0, blue: 0xA6/255.0)
        case .opencode: return Color(red: 0x5B/255.0, green: 0x83/255.0, blue: 0x5B/255.0)
        case .pi: return Color(red: 0xB2/255.0, green: 0x6B/255.0, blue: 0x3D/255.0)
        }
    }
}
