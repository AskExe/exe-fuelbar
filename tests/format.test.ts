import { describe, it, expect } from 'vitest'

import { formatTokens, renderStatusBar } from '../src/format.js'
import type { ProjectSummary, SessionSummary, ClassifiedTurn, ParsedApiCall, TokenUsage } from '../src/types.js'

function zeroUsage(): TokenUsage {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationInputTokens: 0,
    cacheReadInputTokens: 0,
    cachedInputTokens: 0,
    reasoningTokens: 0,
    webSearchRequests: 0,
  }
}

function makeApiCall(overrides: Partial<ParsedApiCall> = {}): ParsedApiCall {
  return {
    provider: 'claude',
    model: 'claude-opus-4-6',
    usage: zeroUsage(),
    costUSD: 0,
    tools: [],
    mcpTools: [],
    hasAgentSpawn: false,
    hasPlanMode: false,
    speed: 'standard',
    timestamp: '',
    bashCommands: [],
    deduplicationKey: `key-${Math.random()}`,
    ...overrides,
  }
}

function makeTurn(overrides: Partial<ClassifiedTurn> = {}): ClassifiedTurn {
  return {
    userMessage: 'hello',
    assistantCalls: [],
    timestamp: '',
    sessionId: 's1',
    category: 'general',
    retries: 0,
    hasEdits: false,
    ...overrides,
  }
}

function makeSession(overrides: Partial<SessionSummary> = {}): SessionSummary {
  return {
    sessionId: 's1',
    project: 'test-project',
    firstTimestamp: '',
    lastTimestamp: '',
    totalCostUSD: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheReadTokens: 0,
    totalCacheWriteTokens: 0,
    apiCalls: 0,
    turns: [],
    modelBreakdown: {},
    toolBreakdown: {},
    mcpBreakdown: {},
    bashBreakdown: {},
    categoryBreakdown: {} as SessionSummary['categoryBreakdown'],
    ...overrides,
  }
}

function makeProject(overrides: Partial<ProjectSummary> = {}): ProjectSummary {
  return {
    project: 'test-project',
    projectPath: '/test/project',
    sessions: [],
    totalCostUSD: 0,
    totalApiCalls: 0,
    ...overrides,
  }
}

describe('formatTokens', () => {
  it('formats 0 as "0"', () => {
    expect(formatTokens(0)).toBe('0')
  })

  it('formats 500 as "500"', () => {
    expect(formatTokens(500)).toBe('500')
  })

  it('formats 1000 as "1.0K"', () => {
    expect(formatTokens(1000)).toBe('1.0K')
  })

  it('formats 1500 as "1.5K"', () => {
    expect(formatTokens(1500)).toBe('1.5K')
  })

  it('formats 999999 as "1000.0K"', () => {
    expect(formatTokens(999999)).toBe('1000.0K')
  })

  it('formats 1000000 as "1.0M"', () => {
    expect(formatTokens(1_000_000)).toBe('1.0M')
  })

  it('formats 2500000 as "2.5M"', () => {
    expect(formatTokens(2_500_000)).toBe('2.5M')
  })
})

describe('renderStatusBar', () => {
  /** Build a midday ISO timestamp for the given date string (YYYY-MM-DD). */
  function middayTs(dateStr: string): string {
    // Use midday to avoid any timezone edge cases
    return `${dateStr}T12:00:00.000Z`
  }

  /** Today's date in YYYY-MM-DD, matching the local-time logic in format.ts. */
  function todayStr(): string {
    const now = new Date()
    const y = now.getFullYear()
    const m = String(now.getMonth() + 1).padStart(2, '0')
    const d = String(now.getDate()).padStart(2, '0')
    return `${y}-${m}-${d}`
  }

  /** First day of the current month. */
  function monthStartStr(): string {
    return `${todayStr().slice(0, 7)}-01`
  }

  it('returns $0.00 for both today and month when projects array is empty', () => {
    const bar = renderStatusBar([])
    expect(bar).toContain('$0.00')
    expect(bar).toContain('Today')
    expect(bar).toContain('Month')
    expect(bar).toContain('0 calls')
  })

  it('shows correct today cost for turns with today timestamps', () => {
    const today = todayStr()
    const call = makeApiCall({ costUSD: 1.50, timestamp: middayTs(today) })
    const turn = makeTurn({ assistantCalls: [call] })
    const session = makeSession({ turns: [turn] })
    const project = makeProject({ sessions: [session] })

    const bar = renderStatusBar([project])
    expect(bar).toContain('$1.50')
  })

  it('shows correct month cost for turns from this month', () => {
    // Use a day earlier in the month (but still this month) to separate
    // month cost from today cost.
    const now = new Date()
    const day = now.getDate()

    // If today is the 1st, we can't pick an earlier day in the same month.
    // In that case both today and month should equal the same value.
    let monthDay: string
    if (day > 1) {
      const earlierDay = String(day - 1).padStart(2, '0')
      monthDay = `${todayStr().slice(0, 7)}-${earlierDay}`
    } else {
      monthDay = todayStr()
    }

    const call = makeApiCall({ costUSD: 3.00, timestamp: middayTs(monthDay) })
    const turn = makeTurn({ assistantCalls: [call] })
    const session = makeSession({ turns: [turn] })
    const project = makeProject({ sessions: [session] })

    const bar = renderStatusBar([project])
    expect(bar).toContain('$3.00')
  })

  it('aggregates costs across multiple projects and sessions', () => {
    const today = todayStr()
    const call1 = makeApiCall({ costUSD: 0.50, timestamp: middayTs(today) })
    const call2 = makeApiCall({ costUSD: 0.75, timestamp: middayTs(today) })
    const turn1 = makeTurn({ assistantCalls: [call1] })
    const turn2 = makeTurn({ assistantCalls: [call2] })

    const project1 = makeProject({
      sessions: [makeSession({ turns: [turn1] })],
    })
    const project2 = makeProject({
      project: 'other-project',
      sessions: [makeSession({ turns: [turn2] })],
    })

    const bar = renderStatusBar([project1, project2])
    expect(bar).toContain('$1.25')
    expect(bar).toContain('2 calls')
  })

  it('does not count turns without assistantCalls', () => {
    const today = todayStr()
    const turnWithCalls = makeTurn({
      assistantCalls: [makeApiCall({ costUSD: 2.00, timestamp: middayTs(today) })],
    })
    const turnWithoutCalls = makeTurn({ assistantCalls: [] })

    const project = makeProject({
      sessions: [makeSession({ turns: [turnWithCalls, turnWithoutCalls] })],
    })

    const bar = renderStatusBar([project])
    expect(bar).toContain('$2.00')
    expect(bar).toContain('1 calls')
  })

  it('skips turns where the first assistant call has no timestamp', () => {
    const callNoTs = makeApiCall({ costUSD: 5.00, timestamp: '' })
    const turn = makeTurn({ assistantCalls: [callNoTs] })
    const project = makeProject({
      sessions: [makeSession({ turns: [turn] })],
    })

    const bar = renderStatusBar([project])
    expect(bar).toContain('$0.00')
  })
})
