import Foundation
import Testing
@testable import ExeWatcherMenubar

@Suite("Provider sum validation")
struct ProviderSumValidationTests {
    @Test("provider costs sum to total cost")
    func providerCostsSumToTotal() {
        let providers: [String: Double] = ["claude": 70, "codex": 30]
        let total = 100.0

        let payload = MenubarPayload(
            generated: "2026-05-07T00:00:00Z",
            cliVersion: nil,
            minAppVersion: nil,
            current: CurrentBlock(
                label: "Today",
                cost: total,
                calls: 100,
                sessions: 5,
                oneShotRate: nil,
                inputTokens: 0,
                outputTokens: 0,
                cacheHitPercent: 0,
                topActivities: [],
                topModels: [],
                providers: providers
            ),
            optimize: OptimizeBlock(findingCount: 0, savingsUSD: 0, topFindings: []),
            history: HistoryBlock(daily: []),
            diagnostics: nil,
            agentStats: nil,
            exeOsDetected: nil,
            statsFileAge: nil,
            projectSpend: nil
        )

        let sum = payload.current.providers.values.reduce(0, +)
        #expect(sum == payload.current.cost)
    }

    @Test("zero-cost providers are preserved in the dict")
    func zeroCostProvidersIncluded() {
        let providers: [String: Double] = ["claude": 50, "codex": 0]

        let payload = MenubarPayload(
            generated: "2026-05-07T00:00:00Z",
            cliVersion: nil,
            minAppVersion: nil,
            current: CurrentBlock(
                label: "Today",
                cost: 50,
                calls: 50,
                sessions: 2,
                oneShotRate: nil,
                inputTokens: 0,
                outputTokens: 0,
                cacheHitPercent: 0,
                topActivities: [],
                topModels: [],
                providers: providers
            ),
            optimize: OptimizeBlock(findingCount: 0, savingsUSD: 0, topFindings: []),
            history: HistoryBlock(daily: []),
            diagnostics: nil,
            agentStats: nil,
            exeOsDetected: nil,
            statsFileAge: nil,
            projectSpend: nil
        )

        #expect(payload.current.providers.count == 2)
        #expect(payload.current.providers["claude"] == 50)
        #expect(payload.current.providers["codex"] == 0)
    }

    @Test("empty providers dict is empty, not nil")
    func emptyProvidersDict() {
        let payload = MenubarPayload(
            generated: "2026-05-07T00:00:00Z",
            cliVersion: nil,
            minAppVersion: nil,
            current: CurrentBlock(
                label: "Today",
                cost: 0,
                calls: 0,
                sessions: 0,
                oneShotRate: nil,
                inputTokens: 0,
                outputTokens: 0,
                cacheHitPercent: 0,
                topActivities: [],
                topModels: [],
                providers: [:]
            ),
            optimize: OptimizeBlock(findingCount: 0, savingsUSD: 0, topFindings: []),
            history: HistoryBlock(daily: []),
            diagnostics: nil,
            agentStats: nil,
            exeOsDetected: nil,
            statsFileAge: nil,
            projectSpend: nil
        )

        #expect(payload.current.providers.isEmpty)
        #expect(payload.current.providers.count == 0)
    }

    @Test("round-trips through JSONDecoder from CLI JSON format")
    func decodeFromCLIJson() throws {
        let json = """
        {
            "generated": "2026-05-07T12:00:00Z",
            "current": {
                "label": "Today",
                "cost": 42.5,
                "calls": 120,
                "sessions": 3,
                "oneShotRate": 0.15,
                "inputTokens": 500000,
                "outputTokens": 80000,
                "cacheHitPercent": 62.3,
                "topActivities": [
                    {"name": "coding", "cost": 30.0, "turns": 50, "oneShotRate": 0.1}
                ],
                "topModels": [
                    {"name": "claude-opus-4", "cost": 35.0, "calls": 80}
                ],
                "providers": {"claude": 35.0, "codex": 7.5}
            },
            "optimize": {
                "findingCount": 2,
                "savingsUSD": 8.5,
                "topFindings": [
                    {"title": "Cache miss", "impact": "high", "savingsUSD": 5.0}
                ]
            },
            "history": {
                "daily": [
                    {
                        "date": "2026-05-07",
                        "cost": 42.5,
                        "calls": 120,
                        "inputTokens": 500000,
                        "outputTokens": 80000,
                        "cacheReadTokens": 100000,
                        "cacheWriteTokens": 20000,
                        "topModels": []
                    }
                ]
            }
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(MenubarPayload.self, from: data)

        #expect(decoded.generated == "2026-05-07T12:00:00Z")
        #expect(decoded.current.cost == 42.5)
        #expect(decoded.current.providers["claude"] == 35.0)
        #expect(decoded.current.providers["codex"] == 7.5)
        #expect(decoded.current.providers.values.reduce(0, +) == decoded.current.cost)
        #expect(decoded.current.topActivities.count == 1)
        #expect(decoded.current.topModels.first?.name == "claude-opus-4")
        #expect(decoded.optimize.findingCount == 2)
        #expect(decoded.optimize.topFindings.first?.savingsUSD == 5.0)
        #expect(decoded.history.daily.count == 1)
        #expect(decoded.diagnostics == nil)
        #expect(decoded.projectSpend == nil)
    }

    @Test("ProjectSpendEntry decodes with optional fields defaulting to zero")
    func projectSpendDecodingDefaults() throws {
        // Minimal JSON: cost24h omitted, should default to 0
        let json = """
        {
            "name": "my-project",
            "cost7d": 15.0,
            "cost30d": 45.0,
            "sessions": 8
        }
        """

        let data = Data(json.utf8)
        let entry = try JSONDecoder().decode(ProjectSpendEntry.self, from: data)

        #expect(entry.name == "my-project")
        #expect(entry.cost24h == 0)
        #expect(entry.cost7d == 15.0)
        #expect(entry.cost30d == 45.0)
        #expect(entry.selectedPeriodCost == 45.0) // defaults to cost30d when missing
        #expect(entry.sessions == 8)
    }
}
