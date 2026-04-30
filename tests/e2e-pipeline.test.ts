import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { mkdtemp, readFile, readdir, rm } from 'fs/promises'
import { join } from 'path'
import { tmpdir } from 'os'

import { aggregateProjectsIntoDays, buildPeriodDataFromDays } from '../src/day-aggregator.js'
import { exportCsv, exportJson, type PeriodExport } from '../src/export.js'
import { buildMenubarPayload, type PeriodData, type ProviderCost } from '../src/menubar-json.js'
import {
  detectJunkReads,
  detectDuplicateReads,
  detectLowReadEditRatio,
  computeHealth,
  type ToolCall,
} from '../src/optimize.js'
import type { ProjectSummary, ClassifiedTurn, ParsedApiCall, SessionSummary, TaskCategory } from '../src/types.js'

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

const ALL_CATEGORIES: TaskCategory[] = [
  'coding', 'debugging', 'feature', 'refactoring', 'testing', 'exploration',
  'planning', 'delegation', 'git', 'build/deploy', 'conversation', 'brainstorming', 'general',
]

function emptyCategoryBreakdown(): SessionSummary['categoryBreakdown'] {
  const bd = {} as SessionSummary['categoryBreakdown']
  for (const cat of ALL_CATEGORIES) {
    bd[cat] = { turns: 0, costUSD: 0, retries: 0, editTurns: 0, oneShotTurns: 0 }
  }
  return bd
}

function makeCall(
  timestamp: string,
  costUSD: number,
  model = 'claude-opus-4-6',
  provider = 'claude',
): ParsedApiCall {
  return {
    provider,
    model,
    usage: {
      inputTokens: 500,
      outputTokens: 250,
      cacheCreationInputTokens: 100,
      cacheReadInputTokens: 200,
      cachedInputTokens: 0,
      reasoningTokens: 0,
      webSearchRequests: 0,
    },
    costUSD,
    tools: ['Read', 'Edit'],
    mcpTools: [],
    hasAgentSpawn: false,
    hasPlanMode: false,
    speed: 'standard',
    timestamp,
    bashCommands: ['git status'],
    deduplicationKey: `dk-${timestamp}-${costUSD}`,
  }
}

function makeTurn(
  timestamp: string,
  costUSD: number,
  opts: Partial<{ category: TaskCategory; model: string; provider: string; hasEdits: boolean; retries: number }> = {},
): ClassifiedTurn {
  const model = opts.model ?? 'claude-opus-4-6'
  const provider = opts.provider ?? 'claude'
  return {
    userMessage: 'fix the tests',
    timestamp,
    sessionId: 'sess-fixture',
    category: opts.category ?? 'coding',
    retries: opts.retries ?? 0,
    hasEdits: opts.hasEdits ?? true,
    assistantCalls: [makeCall(timestamp, costUSD, model, provider)],
  }
}

function makeSession(
  sessionId: string,
  project: string,
  turns: ClassifiedTurn[],
): SessionSummary {
  const totalCost = turns.reduce((s, t) => s + t.assistantCalls.reduce((a, c) => a + c.costUSD, 0), 0)
  const totalInput = turns.reduce((s, t) => s + t.assistantCalls.reduce((a, c) => a + c.usage.inputTokens, 0), 0)
  const totalOutput = turns.reduce((s, t) => s + t.assistantCalls.reduce((a, c) => a + c.usage.outputTokens, 0), 0)
  const totalCacheRead = turns.reduce((s, t) => s + t.assistantCalls.reduce((a, c) => a + c.usage.cacheReadInputTokens, 0), 0)
  const totalCacheWrite = turns.reduce((s, t) => s + t.assistantCalls.reduce((a, c) => a + c.usage.cacheCreationInputTokens, 0), 0)
  const apiCalls = turns.reduce((s, t) => s + t.assistantCalls.length, 0)

  const modelBreakdown: SessionSummary['modelBreakdown'] = {}
  const toolBreakdown: SessionSummary['toolBreakdown'] = {}
  const bashBreakdown: SessionSummary['bashBreakdown'] = {}
  const categoryBreakdown = emptyCategoryBreakdown()

  for (const turn of turns) {
    const cat = turn.category
    categoryBreakdown[cat].turns += 1
    categoryBreakdown[cat].editTurns += turn.hasEdits ? 1 : 0
    categoryBreakdown[cat].oneShotTurns += (turn.hasEdits && turn.retries === 0) ? 1 : 0
    categoryBreakdown[cat].retries += turn.retries

    for (const call of turn.assistantCalls) {
      categoryBreakdown[cat].costUSD += call.costUSD

      if (!modelBreakdown[call.model]) {
        modelBreakdown[call.model] = { calls: 0, costUSD: 0, tokens: { ...call.usage } }
      } else {
        modelBreakdown[call.model].calls += 1
        modelBreakdown[call.model].costUSD += call.costUSD
      }

      for (const tool of call.tools) {
        toolBreakdown[tool] = { calls: (toolBreakdown[tool]?.calls ?? 0) + 1 }
      }

      for (const cmd of call.bashCommands) {
        bashBreakdown[cmd] = { calls: (bashBreakdown[cmd]?.calls ?? 0) + 1 }
      }
    }
  }

  const timestamps = turns.flatMap(t => t.assistantCalls.map(c => c.timestamp))
  const firstTimestamp = timestamps.sort()[0] ?? '2026-04-20T10:00:00Z'
  const lastTimestamp = timestamps.sort().pop() ?? firstTimestamp

  return {
    sessionId,
    project,
    firstTimestamp,
    lastTimestamp,
    totalCostUSD: totalCost,
    totalInputTokens: totalInput,
    totalOutputTokens: totalOutput,
    totalCacheReadTokens: totalCacheRead,
    totalCacheWriteTokens: totalCacheWrite,
    apiCalls,
    turns,
    modelBreakdown,
    toolBreakdown,
    mcpBreakdown: {},
    bashBreakdown,
    categoryBreakdown,
  }
}

function makeProject(projectPath: string, sessions: SessionSummary[]): ProjectSummary {
  return {
    project: projectPath,
    projectPath,
    sessions,
    totalCostUSD: sessions.reduce((s, sess) => s + sess.totalCostUSD, 0),
    totalApiCalls: sessions.reduce((s, sess) => s + sess.apiCalls, 0),
  }
}

// ---------------------------------------------------------------------------
// Temp directory lifecycle
// ---------------------------------------------------------------------------

let tmpDir: string

beforeEach(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), 'e2e-pipeline-'))
})

afterEach(async () => {
  await rm(tmpDir, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------
// Test 1: Parse -> Aggregate -> PeriodData
// ---------------------------------------------------------------------------

describe('Parse -> Aggregate -> PeriodData pipeline', () => {
  it('aggregates project sessions into daily entries and builds correct PeriodData', () => {
    const turns1 = [
      makeTurn('2026-04-20T10:00:00Z', 5.0, { category: 'coding', hasEdits: true }),
      makeTurn('2026-04-20T14:00:00Z', 3.0, { category: 'debugging', hasEdits: true, retries: 1 }),
    ]
    const turns2 = [
      makeTurn('2026-04-21T09:00:00Z', 7.0, { category: 'feature', model: 'gpt-5', provider: 'codex' }),
    ]

    const sess1 = makeSession('sess-1', '/proj/alpha', turns1)
    const sess2 = makeSession('sess-2', '/proj/alpha', turns2)
    const project = makeProject('/proj/alpha', [sess1, sess2])

    const days = aggregateProjectsIntoDays([project])

    expect(days).toHaveLength(2)
    expect(days[0]!.date).toBe('2026-04-20')
    expect(days[1]!.date).toBe('2026-04-21')

    expect(days[0]!.cost).toBe(8)
    expect(days[0]!.calls).toBe(2)
    expect(days[0]!.sessions).toBe(1) // only sess-1 starts on 4/20

    expect(days[1]!.cost).toBe(7)
    expect(days[1]!.calls).toBe(1)
    expect(days[1]!.sessions).toBe(1)

    // Verify model breakdown on day 1
    expect(days[0]!.models['claude-opus-4-6']).toBeDefined()
    expect(days[0]!.models['claude-opus-4-6']!.calls).toBe(2)

    // Verify model breakdown on day 2
    expect(days[1]!.models['gpt-5']).toBeDefined()
    expect(days[1]!.models['gpt-5']!.calls).toBe(1)

    // Build PeriodData from the days
    const periodData = buildPeriodDataFromDays(days, 'Week')

    expect(periodData.label).toBe('Week')
    expect(periodData.cost).toBe(15)
    expect(periodData.calls).toBe(3)
    expect(periodData.sessions).toBe(2)
    expect(periodData.inputTokens).toBe(1500)  // 500 * 3 calls
    expect(periodData.outputTokens).toBe(750)   // 250 * 3 calls
    expect(periodData.cacheReadTokens).toBe(600) // 200 * 3 calls
    expect(periodData.cacheWriteTokens).toBe(300) // 100 * 3 calls

    // Models sorted by cost descending
    expect(periodData.models[0]!.name).toBe('claude-opus-4-6')
    expect(periodData.models[0]!.cost).toBe(8)
    expect(periodData.models[0]!.calls).toBe(2)
    expect(periodData.models[1]!.name).toBe('gpt-5')
    expect(periodData.models[1]!.cost).toBe(7)

    // Categories present
    const codingCat = periodData.categories.find(c => c.name === 'Coding')
    expect(codingCat).toBeDefined()
    expect(codingCat!.turns).toBe(1)
    expect(codingCat!.cost).toBe(5)

    const featureCat = periodData.categories.find(c => c.name === 'Feature Dev')
    expect(featureCat).toBeDefined()
    expect(featureCat!.turns).toBe(1)
    expect(featureCat!.cost).toBe(7)
  })

  it('handles empty projects gracefully', () => {
    const days = aggregateProjectsIntoDays([])
    expect(days).toEqual([])

    const periodData = buildPeriodDataFromDays(days, 'Today')
    expect(periodData.cost).toBe(0)
    expect(periodData.calls).toBe(0)
    expect(periodData.sessions).toBe(0)
    expect(periodData.models).toEqual([])
    expect(periodData.categories).toEqual([])
  })

  it('tracks editTurns and oneShotTurns correctly through the pipeline', () => {
    const turns = [
      makeTurn('2026-04-20T10:00:00Z', 2.0, { hasEdits: true, retries: 0 }),  // oneShot
      makeTurn('2026-04-20T11:00:00Z', 3.0, { hasEdits: true, retries: 2 }),  // not oneShot (retried)
      makeTurn('2026-04-20T12:00:00Z', 1.0, { hasEdits: false }),              // not an edit turn
    ]
    const sess = makeSession('sess-1', '/proj', turns)
    const project = makeProject('/proj', [sess])

    const days = aggregateProjectsIntoDays([project])
    expect(days[0]!.editTurns).toBe(2)
    expect(days[0]!.oneShotTurns).toBe(1)

    const periodData = buildPeriodDataFromDays(days, 'Today')
    const codingCat = periodData.categories.find(c => c.name === 'Coding')!
    expect(codingCat.editTurns).toBe(2)
    expect(codingCat.oneShotTurns).toBe(1)
  })
})

// ---------------------------------------------------------------------------
// Test 2: Parse -> Export CSV
// ---------------------------------------------------------------------------

describe('Parse -> Export CSV pipeline', () => {
  it('exports CSV files with correct headers and data rows', async () => {
    const turns = [
      makeTurn('2026-04-20T10:00:00Z', 5.50),
      makeTurn('2026-04-20T14:00:00Z', 3.25),
    ]
    const sess = makeSession('sess-csv', '/proj/csv-test', turns)
    const project = makeProject('/proj/csv-test', [sess])

    const periods: PeriodExport[] = [
      { label: '30 Days', projects: [project] },
    ]

    const outputPath = join(tmpDir, 'csv-export.csv')
    const folder = await exportCsv(periods, outputPath)

    const entries = await readdir(folder)
    expect(entries).toContain('projects.csv')
    expect(entries).toContain('models.csv')
    expect(entries).toContain('sessions.csv')
    expect(entries).toContain('summary.csv')
    expect(entries).toContain('daily.csv')
    expect(entries).toContain('tools.csv')
    expect(entries).toContain('shell-commands.csv')
    expect(entries).toContain('README.txt')

    // Check projects.csv has the project path and cost
    const projectsCsv = await readFile(join(folder, 'projects.csv'), 'utf-8')
    expect(projectsCsv).toContain('Project')
    expect(projectsCsv).toContain('Cost')
    expect(projectsCsv).toContain('/proj/csv-test')

    // Check sessions.csv has session ID
    const sessionsCsv = await readFile(join(folder, 'sessions.csv'), 'utf-8')
    expect(sessionsCsv).toContain('Session ID')
    expect(sessionsCsv).toContain('sess-csv')

    // Check models.csv has model name
    const modelsCsv = await readFile(join(folder, 'models.csv'), 'utf-8')
    expect(modelsCsv).toContain('Model')
    expect(modelsCsv).toContain('claude-opus-4-6')

    // Check summary.csv has period label
    const summaryCsv = await readFile(join(folder, 'summary.csv'), 'utf-8')
    expect(summaryCsv).toContain('30 Days')

    // Check tools.csv has tool names from fixture
    const toolsCsv = await readFile(join(folder, 'tools.csv'), 'utf-8')
    expect(toolsCsv).toContain('Read')
    expect(toolsCsv).toContain('Edit')
  })

  it('handles multiple periods in summary', async () => {
    const turns = [makeTurn('2026-04-20T10:00:00Z', 2.00)]
    const sess = makeSession('sess-multi', '/proj', turns)
    const project = makeProject('/proj', [sess])

    const periods: PeriodExport[] = [
      { label: 'Today', projects: [project] },
      { label: '7 Days', projects: [project] },
      { label: '30 Days', projects: [project] },
    ]

    const outputPath = join(tmpDir, 'multi-period.csv')
    const folder = await exportCsv(periods, outputPath)

    const summaryCsv = await readFile(join(folder, 'summary.csv'), 'utf-8')
    expect(summaryCsv).toContain('Today')
    expect(summaryCsv).toContain('7 Days')
    expect(summaryCsv).toContain('30 Days')
  })
})

// ---------------------------------------------------------------------------
// Test 3: Parse -> Export JSON
// ---------------------------------------------------------------------------

describe('Parse -> Export JSON pipeline', () => {
  it('exports valid JSON matching expected schema', async () => {
    const turns = [
      makeTurn('2026-04-20T10:00:00Z', 4.00, { category: 'coding' }),
      makeTurn('2026-04-21T09:00:00Z', 6.00, { category: 'debugging' }),
    ]
    const sess = makeSession('sess-json', '/proj/json-test', turns)
    const project = makeProject('/proj/json-test', [sess])

    const periods: PeriodExport[] = [
      { label: '30 Days', projects: [project] },
    ]

    const outputPath = join(tmpDir, 'export.json')
    const filePath = await exportJson(periods, outputPath)

    const raw = await readFile(filePath, 'utf-8')
    const data = JSON.parse(raw)

    // Top-level schema
    expect(data.schema).toBe('exe-watcher.export.v2')
    expect(data.generated).toMatch(/^\d{4}-\d{2}-\d{2}T/)
    expect(data.currency).toHaveProperty('code')
    expect(data.currency).toHaveProperty('rate')
    expect(data.currency).toHaveProperty('symbol')

    // Summary
    expect(data.summary).toBeInstanceOf(Array)
    expect(data.summary.length).toBe(1)
    expect(data.summary[0].Period).toBe('30 Days')

    // Periods
    expect(data.periods).toBeInstanceOf(Array)
    expect(data.periods[0].label).toBe('30 Days')
    expect(data.periods[0].daily).toBeInstanceOf(Array)
    expect(data.periods[0].models).toBeInstanceOf(Array)
    expect(data.periods[0].activity).toBeInstanceOf(Array)

    // Projects
    expect(data.projects).toBeInstanceOf(Array)
    expect(data.projects.length).toBe(1)
    expect(data.projects[0].Project).toBe('/proj/json-test')

    // Sessions
    expect(data.sessions).toBeInstanceOf(Array)
    expect(data.sessions[0]['Session ID']).toBe('sess-json')

    // Tools
    expect(data.tools).toBeInstanceOf(Array)
    expect(data.tools.some((t: Record<string, unknown>) => t.Tool === 'Read')).toBe(true)

    // Shell commands
    expect(data.shellCommands).toBeInstanceOf(Array)
  })

  it('adds .json extension if missing from output path', async () => {
    const sess = makeSession('s1', '/p', [makeTurn('2026-04-20T10:00:00Z', 1.0)])
    const periods: PeriodExport[] = [{ label: '30 Days', projects: [makeProject('/p', [sess])] }]

    const outputPath = join(tmpDir, 'no-ext')
    const filePath = await exportJson(periods, outputPath)
    expect(filePath.endsWith('.json')).toBe(true)

    const raw = await readFile(filePath, 'utf-8')
    const data = JSON.parse(raw)
    expect(data.schema).toBe('exe-watcher.export.v2')
  })
})

// ---------------------------------------------------------------------------
// Test 4: Parse -> Menubar JSON
// ---------------------------------------------------------------------------

describe('Parse -> Menubar JSON pipeline', () => {
  it('builds correct menubar payload structure from PeriodData', () => {
    const turns = [
      makeTurn('2026-04-20T10:00:00Z', 5.0, { category: 'coding', hasEdits: true }),
      makeTurn('2026-04-20T11:00:00Z', 3.0, { category: 'debugging', hasEdits: true, retries: 1 }),
      makeTurn('2026-04-20T12:00:00Z', 2.0, { category: 'conversation', hasEdits: false }),
    ]
    const sess = makeSession('sess-mb', '/proj/mb', turns)
    const project = makeProject('/proj/mb', [sess])

    // Run through the aggregation pipeline
    const days = aggregateProjectsIntoDays([project])
    const periodData = buildPeriodDataFromDays(days, 'Today')

    // Providers
    const providers: ProviderCost[] = [
      { name: 'Claude', cost: 10.0 },
      { name: 'Codex', cost: 0 },
    ]

    const payload = buildMenubarPayload(periodData, providers, null)

    // Top-level structure
    expect(payload).toHaveProperty('generated')
    expect(payload).toHaveProperty('current')
    expect(payload).toHaveProperty('optimize')
    expect(payload).toHaveProperty('history')

    // Current block
    expect(payload.current.label).toBe('Today')
    expect(payload.current.cost).toBe(10)
    expect(payload.current.calls).toBe(3)
    expect(payload.current.sessions).toBe(1)

    // OneShotRate: 2 edits, 1 one-shot (coding has edits+no-retries), debugging has edits+retries
    expect(payload.current.oneShotRate).toBeCloseTo(1 / 2)

    // Cache hit percent from real tokens
    expect(payload.current.cacheHitPercent).toBeGreaterThan(0)

    // Activities
    expect(payload.current.topActivities.length).toBeGreaterThanOrEqual(2)
    const codingActivity = payload.current.topActivities.find(a => a.name === 'Coding')
    expect(codingActivity).toBeDefined()
    expect(codingActivity!.cost).toBe(5)

    // Models
    expect(payload.current.topModels.length).toBe(1)
    expect(payload.current.topModels[0]!.name).toBe('claude-opus-4-6')

    // Providers
    expect(payload.current.providers).toEqual({ claude: 10.0, codex: 0 })

    // Optimize (null input)
    expect(payload.optimize).toEqual({ findingCount: 0, savingsUSD: 0, topFindings: [] })

    // History (empty when not provided)
    expect(payload.history.daily).toEqual([])
  })

  it('includes optimize findings in payload when provided', () => {
    const periodData: PeriodData = {
      label: 'Today',
      cost: 50, calls: 100, sessions: 5,
      inputTokens: 10000, outputTokens: 5000,
      cacheReadTokens: 8000, cacheWriteTokens: 1000,
      categories: [],
      models: [{ name: 'claude-opus-4-6', cost: 50, calls: 100 }],
    }

    const optimizeResult = {
      findings: [
        {
          title: 'Junk reads found',
          explanation: 'Reading node_modules',
          impact: 'high' as const,
          tokensSaved: 5000,
          fix: { type: 'paste' as const, label: 'Add to CLAUDE.md', text: 'Do not read node_modules' },
        },
        {
          title: 'Duplicate reads',
          explanation: 'Same files re-read',
          impact: 'medium' as const,
          tokensSaved: 3000,
          fix: { type: 'paste' as const, label: 'Tip:', text: 'Point Claude at exact locations' },
        },
      ],
      costRate: 0.00002,
      healthScore: 70,
      healthGrade: 'C' as const,
    }

    const payload = buildMenubarPayload(periodData, [], optimizeResult)

    expect(payload.optimize.findingCount).toBe(2)
    expect(payload.optimize.savingsUSD).toBeCloseTo((5000 + 3000) * 0.00002)
    expect(payload.optimize.topFindings).toHaveLength(2)
    expect(payload.optimize.topFindings[0]!.title).toBe('Junk reads found')
    expect(payload.optimize.topFindings[0]!.impact).toBe('high')
    expect(payload.optimize.topFindings[0]!.savingsUSD).toBeCloseTo(5000 * 0.00002)
  })

  it('includes daily history entries sorted and capped', () => {
    const periodData: PeriodData = {
      label: 'Today', cost: 0, calls: 0, sessions: 0,
      inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
      categories: [], models: [],
    }

    const history = [
      { date: '2026-04-20', cost: 10, calls: 50, inputTokens: 100, outputTokens: 200, cacheReadTokens: 0, cacheWriteTokens: 0, topModels: [] },
      { date: '2026-04-19', cost: 8, calls: 40, inputTokens: 80, outputTokens: 160, cacheReadTokens: 0, cacheWriteTokens: 0, topModels: [] },
    ]

    const payload = buildMenubarPayload(periodData, [], null, history)

    expect(payload.history.daily).toHaveLength(2)
    // Should be sorted ascending
    expect(payload.history.daily[0]!.date).toBe('2026-04-19')
    expect(payload.history.daily[1]!.date).toBe('2026-04-20')
  })
})

// ---------------------------------------------------------------------------
// Test 5: Full optimize pipeline (detector-level, no scanSessions)
// ---------------------------------------------------------------------------

describe('Optimize detector pipeline', () => {
  it('detects junk reads from tool call data', () => {
    const calls: ToolCall[] = [
      ...Array.from({ length: 10 }, (_, i) => ({
        name: 'Read',
        input: { file_path: `/proj/node_modules/pkg-${i}/index.js` },
        sessionId: 'sess-1',
        project: '/proj',
      })),
      ...Array.from({ length: 5 }, (_, i) => ({
        name: 'Read',
        input: { file_path: `/proj/.git/objects/abc${i}` },
        sessionId: 'sess-1',
        project: '/proj',
      })),
    ]

    const finding = detectJunkReads(calls)
    expect(finding).not.toBeNull()
    expect(finding!.title).toContain('reading')
    expect(finding!.impact).toBe('medium')
    expect(finding!.tokensSaved).toBeGreaterThan(0)
    expect(finding!.fix.type).toBe('paste')
  })

  it('detects duplicate reads from tool call data', () => {
    // Same file read 8 times in the same session
    const calls: ToolCall[] = Array.from({ length: 8 }, () => ({
      name: 'Read',
      input: { file_path: '/proj/src/main.ts' },
      sessionId: 'sess-1',
      project: '/proj',
    }))

    const finding = detectDuplicateReads(calls)
    expect(finding).not.toBeNull()
    expect(finding!.title).toContain('re-reading')
    expect(finding!.tokensSaved).toBeGreaterThan(0)
  })

  it('detects low read/edit ratio', () => {
    const calls: ToolCall[] = [
      ...Array.from({ length: 3 }, () => ({
        name: 'Read',
        input: {},
        sessionId: 'sess-1',
        project: '/proj',
      })),
      ...Array.from({ length: 15 }, () => ({
        name: 'Edit',
        input: {},
        sessionId: 'sess-1',
        project: '/proj',
      })),
    ]

    const finding = detectLowReadEditRatio(calls)
    expect(finding).not.toBeNull()
    expect(finding!.title).toContain('edits more than it reads')
    expect(finding!.impact).toBe('high')
  })

  it('computes health score from combined findings', () => {
    const junkCalls: ToolCall[] = Array.from({ length: 25 }, (_, i) => ({
      name: 'Read',
      input: { file_path: `/proj/node_modules/pkg${i}.js` },
      sessionId: 'sess-1',
      project: '/proj',
    }))
    const dupCalls: ToolCall[] = Array.from({ length: 10 }, () => ({
      name: 'Read',
      input: { file_path: '/proj/src/index.ts' },
      sessionId: 'sess-1',
      project: '/proj',
    }))
    const editCalls: ToolCall[] = [
      ...Array.from({ length: 5 }, () => ({ name: 'Read', input: {}, sessionId: 's2', project: '/proj' })),
      ...Array.from({ length: 15 }, () => ({ name: 'Edit', input: {}, sessionId: 's2', project: '/proj' })),
    ]

    const findings = [
      detectJunkReads(junkCalls),
      detectDuplicateReads(dupCalls),
      detectLowReadEditRatio(editCalls),
    ].filter((f): f is NonNullable<typeof f> => f !== null)

    expect(findings.length).toBeGreaterThanOrEqual(2)

    const { score, grade } = computeHealth(findings)
    expect(score).toBeLessThan(100)
    expect(score).toBeGreaterThanOrEqual(0)
    expect(['A', 'B', 'C', 'D', 'F']).toContain(grade)
  })

  it('returns clean health when no waste is detected', () => {
    const { score, grade } = computeHealth([])
    expect(score).toBe(100)
    expect(grade).toBe('A')
  })
})
