import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, writeFile, rm, mkdir, utimes } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'

vi.mock('os', async (importOriginal) => {
  const actual = await importOriginal<typeof import('os')>()
  return {
    ...actual,
    homedir: vi.fn(() => actual.homedir()),
  }
})

import { homedir } from 'os'
import {
  readCachedResults,
  writeCachedResults,
} from '../src/cursor-cache.js'

import type { ParsedProviderCall } from '../src/providers/types.js'

function makeCall(overrides: Partial<ParsedProviderCall> = {}): ParsedProviderCall {
  return {
    provider: 'cursor',
    model: 'gpt-4',
    inputTokens: 100,
    outputTokens: 50,
    cacheCreationInputTokens: 0,
    cacheReadInputTokens: 0,
    cachedInputTokens: 0,
    reasoningTokens: 0,
    webSearchRequests: 0,
    costUSD: 0.01,
    tools: [],
    bashCommands: [],
    timestamp: '2026-04-25T12:00:00Z',
    speed: 'standard',
    deduplicationKey: 'key-1',
    userMessage: 'test',
    sessionId: 'sess-1',
    ...overrides,
  }
}

const tmpDirs: string[] = []
let fakeHome: string

beforeEach(async () => {
  fakeHome = await mkdtemp(join(tmpdir(), 'exe-fuelbar-cc-'))
  tmpDirs.push(fakeHome)
  vi.mocked(homedir).mockReturnValue(fakeHome)
})

afterEach(async () => {
  vi.mocked(homedir).mockRestore()
  while (tmpDirs.length > 0) {
    const d = tmpDirs.pop()
    if (d) await rm(d, { recursive: true, force: true })
  }
})

async function createMockDb(dir: string, content = 'mock-db-data'): Promise<string> {
  const dbPath = join(dir, 'cursor.db')
  await writeFile(dbPath, content)
  return dbPath
}

describe('readCachedResults', () => {
  it('returns null when no cache file exists', async () => {
    const dbPath = await createMockDb(fakeHome)
    const result = await readCachedResults(dbPath)
    expect(result).toBeNull()
  })

  it('returns null when db file does not exist', async () => {
    const result = await readCachedResults(join(fakeHome, 'nonexistent.db'))
    expect(result).toBeNull()
  })
})

describe('writeCachedResults + readCachedResults', () => {
  it('round-trips correctly', async () => {
    const dbPath = await createMockDb(fakeHome)
    const calls = [
      makeCall({ deduplicationKey: 'a', costUSD: 0.05 }),
      makeCall({ deduplicationKey: 'b', costUSD: 0.10 }),
    ]

    await writeCachedResults(dbPath, calls)
    const result = await readCachedResults(dbPath)
    expect(result).not.toBeNull()
    expect(result).toHaveLength(2)
    expect(result![0].deduplicationKey).toBe('a')
    expect(result![0].costUSD).toBe(0.05)
    expect(result![1].deduplicationKey).toBe('b')
    expect(result![1].costUSD).toBe(0.10)
  })

  it('round-trips empty calls array', async () => {
    const dbPath = await createMockDb(fakeHome)
    await writeCachedResults(dbPath, [])
    const result = await readCachedResults(dbPath)
    expect(result).toEqual([])
  })
})

describe('cache invalidation', () => {
  it('returns null when db mtime changed (stale cache)', async () => {
    const dbPath = await createMockDb(fakeHome)
    const calls = [makeCall()]

    await writeCachedResults(dbPath, calls)

    // Verify cache works before mtime change
    const before = await readCachedResults(dbPath)
    expect(before).not.toBeNull()

    // Change the mtime of the db file
    const pastTime = new Date(Date.now() - 60_000)
    await utimes(dbPath, pastTime, pastTime)

    const result = await readCachedResults(dbPath)
    expect(result).toBeNull()
  })

  it('returns null when db size changed', async () => {
    const dbPath = await createMockDb(fakeHome, 'original-data')
    const calls = [makeCall()]

    await writeCachedResults(dbPath, calls)

    // Verify cache works before size change
    const before = await readCachedResults(dbPath)
    expect(before).not.toBeNull()

    // Rewrite db with different size content, preserving mtime
    const { stat } = await import('fs/promises')
    const origStat = await stat(dbPath)
    await writeFile(dbPath, 'this-is-different-size-content-that-will-invalidate')
    // Restore original mtime so only size differs
    await utimes(dbPath, origStat.atime, origStat.mtime)

    const result = await readCachedResults(dbPath)
    expect(result).toBeNull()
  })
})

describe('writeCachedResults edge cases', () => {
  it('silently handles missing db (no throw)', async () => {
    const missingPath = join(fakeHome, 'does-not-exist.db')
    // Should not throw
    await expect(writeCachedResults(missingPath, [makeCall()])).resolves.toBeUndefined()
  })

  it('creates cache directory if it does not exist', async () => {
    // Point homedir to a fresh location with no .cache directory
    const freshHome = await mkdtemp(join(tmpdir(), 'exe-fuelbar-fresh-'))
    tmpDirs.push(freshHome)
    vi.mocked(homedir).mockReturnValue(freshHome)

    const dbPath = await createMockDb(freshHome)
    const calls = [makeCall()]

    await writeCachedResults(dbPath, calls)
    const result = await readCachedResults(dbPath)
    expect(result).not.toBeNull()
    expect(result).toHaveLength(1)
  })
})
