import { execFile } from 'child_process'
import { join } from 'path'

import { describe, expect, it } from 'vitest'

// ---------------------------------------------------------------------------
// Helper: run the CLI and parse JSON output
// ---------------------------------------------------------------------------

const CLI_ENTRY = join(process.cwd(), 'src', 'cli.ts')

const PERIODS = ['today', 'week', '30days', 'month', 'all'] as const
type Period = (typeof PERIODS)[number]

function localDateKey(date = new Date()): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function runCLI(
  period: Period,
  provider = 'all',
): Promise<{ data: Record<string, unknown>; raw: string }> {
  return new Promise((resolve, reject) => {
    const args = [
      CLI_ENTRY,
      'status',
      '--format', 'menubar-json',
      '--period', period,
      '--provider', provider,
      '--no-optimize',
    ]

    execFile('npx', ['tsx', ...args], {
      timeout: 30_000,
      env: { ...process.env, NODE_NO_WARNINGS: '1' },
    }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(
          `CLI failed (period=${period}, provider=${provider}):\n${stderr}\n${stdout}\n${err.message}`,
        ))
        return
      }
      try {
        const data = JSON.parse(stdout.trim())
        resolve({ data, raw: stdout.trim() })
      } catch {
        reject(new Error(
          `Failed to parse JSON (period=${period}, provider=${provider}):\n${stdout}`,
        ))
      }
    })
  })
}

// ---------------------------------------------------------------------------
// Cache: avoid running the CLI more than once per (period, provider) combo
// ---------------------------------------------------------------------------

const cache = new Map<string, Promise<{ data: Record<string, unknown>; raw: string }>>()

function getCLI(period: Period, provider = 'all') {
  const key = `${period}:${provider}`
  if (!cache.has(key)) {
    cache.set(key, runCLI(period, provider))
  }
  return cache.get(key)!
}

// Pre-warm all period+all combos (they run in parallel)
const allPeriodResults = Object.fromEntries(
  PERIODS.map((p) => [p, getCLI(p, 'all')] as const),
) as Record<Period, Promise<{ data: Record<string, unknown>; raw: string }>>

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('CLI menubar-json E2E', { timeout: 60_000 }, () => {
  // =========================================================================
  // 1. Schema Validation
  // =========================================================================
  describe('Schema Validation', () => {
    const REQUIRED_TOP_KEYS = [
      'generated',
      'current',
      'optimize',
      'history',
      'diagnostics',
    ] as const

    const REQUIRED_CURRENT_KEYS = [
      'label',
      'cost',
      'calls',
      'sessions',
      'oneShotRate',
      'inputTokens',
      'outputTokens',
      'cacheHitPercent',
      'topActivities',
      'topModels',
      'providers',
    ] as const

    describe.each(PERIODS)('period=%s, provider=all', (period) => {
      it('returns valid JSON with all required top-level keys', async () => {
        const { data } = await allPeriodResults[period]
        for (const key of REQUIRED_TOP_KEYS) {
          expect(data, `missing top-level key: ${key}`).toHaveProperty(key)
        }
      })

      it('`generated` is a valid ISO timestamp', async () => {
        const { data } = await allPeriodResults[period]
        expect(data.generated).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        const ts = new Date(data.generated as string)
        expect(ts.getTime()).not.toBeNaN()
      })

      it('`current` contains all required keys', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as Record<string, unknown>
        for (const key of REQUIRED_CURRENT_KEYS) {
          expect(current, `missing current key: ${key}`).toHaveProperty(key)
        }
      })

      it('`current.providers` is a plain object (not an array)', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as Record<string, unknown>
        expect(Array.isArray(current.providers)).toBe(false)
        expect(typeof current.providers).toBe('object')
        expect(current.providers).not.toBeNull()
      })
    })
  })

  // =========================================================================
  // 2. Provider Cost Consistency
  // =========================================================================
  describe('Provider Cost Consistency', () => {
    describe.each(PERIODS)('period=%s', (period) => {
      it('sum of provider costs approximately equals current.cost (within $0.01)', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as {
          cost: number
          providers: Record<string, number>
        }
        const providerSum = Object.values(current.providers).reduce(
          (sum, v) => sum + v,
          0,
        )
        expect(Math.abs(providerSum - current.cost)).toBeLessThanOrEqual(0.01)
      })

      it('no providers have negative costs', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as { providers: Record<string, number> }
        for (const [name, cost] of Object.entries(current.providers)) {
          expect(cost, `provider "${name}" has negative cost`).toBeGreaterThanOrEqual(0)
        }
      })
    })
  })

  // =========================================================================
  // 3. Period Monotonicity
  // =========================================================================
  describe('Period Monotonicity', () => {
    async function getMetrics(period: Period) {
      const { data } = await allPeriodResults[period]
      const c = data.current as { cost: number; calls: number; sessions: number }
      return c
    }

    it('week.cost >= today.cost', async () => {
      const today = await getMetrics('today')
      const week = await getMetrics('week')
      expect(week.cost).toBeGreaterThanOrEqual(today.cost)
    })

    it('all.cost >= week.cost', async () => {
      const week = await getMetrics('week')
      const all = await getMetrics('all')
      expect(all.cost).toBeGreaterThanOrEqual(week.cost)
    })

    it('all.cost >= 30days.cost', async () => {
      const d30 = await getMetrics('30days')
      const all = await getMetrics('all')
      expect(all.cost).toBeGreaterThanOrEqual(d30.cost)
    })

    it('all.sessions >= today.sessions', async () => {
      const today = await getMetrics('today')
      const all = await getMetrics('all')
      expect(all.sessions).toBeGreaterThanOrEqual(today.sessions)
    })

    it('all.calls >= today.calls', async () => {
      const today = await getMetrics('today')
      const all = await getMetrics('all')
      expect(all.calls).toBeGreaterThanOrEqual(today.calls)
    })

    it('week.calls >= today.calls', async () => {
      const today = await getMetrics('today')
      const week = await getMetrics('week')
      expect(week.calls).toBeGreaterThanOrEqual(today.calls)
    })

    it('week.sessions >= today.sessions', async () => {
      const today = await getMetrics('today')
      const week = await getMetrics('week')
      expect(week.sessions).toBeGreaterThanOrEqual(today.sessions)
    })

    it('all.calls >= week.calls', async () => {
      const week = await getMetrics('week')
      const all = await getMetrics('all')
      expect(all.calls).toBeGreaterThanOrEqual(week.calls)
    })

    it('all.sessions >= week.sessions', async () => {
      const week = await getMetrics('week')
      const all = await getMetrics('all')
      expect(all.sessions).toBeGreaterThanOrEqual(week.sessions)
    })
  })

  // =========================================================================
  // 4. Project Spend Integrity
  // =========================================================================
  describe('Project Spend Integrity', () => {
    describe.each(PERIODS)('period=%s', (period) => {
      it('no entries have worktree paths in the name', async () => {
        const { data } = await allPeriodResults[period]
        const projectSpend = data.projectSpend as
          | Array<{ name: string }>
          | null
        if (!projectSpend) return

        for (const entry of projectSpend) {
          expect(
            entry.name,
            `project "${entry.name}" looks like a worktree path`,
          ).not.toMatch(/--worktrees-|\.worktrees/)
        }
      })

      it('all entries have selectedPeriodCost > 0', async () => {
        const { data } = await allPeriodResults[period]
        const projectSpend = data.projectSpend as
          | Array<{ name: string; selectedPeriodCost: number }>
          | null
        if (!projectSpend) return

        for (const entry of projectSpend) {
          expect(
            entry.selectedPeriodCost,
            `project "${entry.name}" has non-positive selectedPeriodCost`,
          ).toBeGreaterThan(0)
        }
      })

      it('cost30d >= cost7d >= cost24h (when non-zero)', async () => {
        const { data } = await allPeriodResults[period]
        const projectSpend = data.projectSpend as
          | Array<{ name: string; cost24h: number; cost7d: number; cost30d: number }>
          | null
        if (!projectSpend) return

        for (const entry of projectSpend) {
          if (entry.cost7d > 0 && entry.cost24h > 0) {
            expect(
              entry.cost7d,
              `project "${entry.name}": cost7d < cost24h`,
            ).toBeGreaterThanOrEqual(entry.cost24h)
          }
          if (entry.cost30d > 0 && entry.cost7d > 0) {
            expect(
              entry.cost30d,
              `project "${entry.name}": cost30d < cost7d`,
            ).toBeGreaterThanOrEqual(entry.cost7d)
          }
        }
      })
    })
  })

  // =========================================================================
  // 5. History Integrity
  // =========================================================================
  describe('History Integrity', () => {
    describe.each(PERIODS)('period=%s', (period) => {
      it('daily history length <= 365', async () => {
        const { data } = await allPeriodResults[period]
        const history = data.history as { daily: unknown[] }
        expect(history.daily.length).toBeLessThanOrEqual(365)
      })

      it('all dates are valid yyyy-MM-dd format', async () => {
        const { data } = await allPeriodResults[period]
        const history = data.history as {
          daily: Array<{ date: string }>
        }
        for (const entry of history.daily) {
          expect(entry.date).toMatch(/^\d{4}-\d{2}-\d{2}$/)
          const parsed = new Date(entry.date + 'T00:00:00Z')
          expect(parsed.getTime()).not.toBeNaN()
        }
      })

      it('dates are sorted ascending', async () => {
        const { data } = await allPeriodResults[period]
        const history = data.history as {
          daily: Array<{ date: string }>
        }
        for (let i = 1; i < history.daily.length; i++) {
          expect(
            history.daily[i]!.date >= history.daily[i - 1]!.date,
            `dates not ascending at index ${i}: ${history.daily[i - 1]!.date} > ${history.daily[i]!.date}`,
          ).toBe(true)
        }
      })

      it('each history entry has non-negative cost and calls', async () => {
        const { data } = await allPeriodResults[period]
        const history = data.history as {
          daily: Array<{ date: string; cost: number; calls: number }>
        }
        for (const entry of history.daily) {
          expect(entry.cost, `negative cost on ${entry.date}`).toBeGreaterThanOrEqual(0)
          expect(entry.calls, `negative calls on ${entry.date}`).toBeGreaterThanOrEqual(0)
        }
      })
    })

    it('today period includes today\'s date as the last history entry', async () => {
      const { data } = await allPeriodResults['today']
      const history = data.history as {
        daily: Array<{ date: string }>
      }
      if (history.daily.length === 0) return // no data today

      const todayStr = localDateKey()
      const lastEntry = history.daily[history.daily.length - 1]!
      expect(lastEntry.date).toBe(todayStr)
    })
  })

  // =========================================================================
  // 6. Session/Call Relationship
  // =========================================================================
  describe('Session/Call Relationship', () => {
    describe.each(PERIODS)('period=%s', (period) => {
      it('sessions > 0 when calls > 0', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as { calls: number; sessions: number }
        if (current.calls > 0) {
          expect(current.sessions).toBeGreaterThan(0)
        }
      })

      it('calls >= sessions (at least 1 call per session)', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as { calls: number; sessions: number }
        expect(current.calls).toBeGreaterThanOrEqual(current.sessions)
      })
    })
  })

  // =========================================================================
  // 7. Token Sanity
  // =========================================================================
  describe('Token Sanity', () => {
    describe.each(PERIODS)('period=%s', (period) => {
      it('cacheHitPercent is between 0 and 100', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as { cacheHitPercent: number }
        expect(current.cacheHitPercent).toBeGreaterThanOrEqual(0)
        expect(current.cacheHitPercent).toBeLessThanOrEqual(100)
      })

      it('inputTokens >= 0', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as { inputTokens: number }
        expect(current.inputTokens).toBeGreaterThanOrEqual(0)
      })

      it('outputTokens >= 0', async () => {
        const { data } = await allPeriodResults[period]
        const current = data.current as { outputTokens: number }
        expect(current.outputTokens).toBeGreaterThanOrEqual(0)
      })
    })
  })
})
