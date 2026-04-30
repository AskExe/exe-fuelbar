import { readFile, mkdir, stat, rename } from 'fs/promises'
import { open } from 'fs/promises'
import { join } from 'path'
import { randomBytes } from 'crypto'

import { getCacheDir } from './cache-dir.js'
import type { ParsedProviderCall } from './providers/types.js'

type ResultCache = {
  dbMtimeMs: number
  dbSizeBytes: number
  calls: ParsedProviderCall[]
}

const CACHE_FILE = 'cursor-results.json'

function getCachePath(): string {
  return join(getCacheDir(), CACHE_FILE)
}

async function getDbFingerprint(dbPath: string): Promise<{ mtimeMs: number; size: number } | null> {
  try {
    const s = await stat(dbPath)
    return { mtimeMs: s.mtimeMs, size: s.size }
  } catch {
    return null
  }
}

export async function readCachedResults(dbPath: string): Promise<ParsedProviderCall[] | null> {
  try {
    const fp = await getDbFingerprint(dbPath)
    if (!fp) return null

    const raw = await readFile(getCachePath(), 'utf-8')
    const cache = JSON.parse(raw) as ResultCache

    if (cache.dbMtimeMs === fp.mtimeMs && cache.dbSizeBytes === fp.size) {
      return cache.calls
    }
    return null
  } catch {
    return null
  }
}

export async function writeCachedResults(dbPath: string, calls: ParsedProviderCall[]): Promise<void> {
  try {
    const fp = await getDbFingerprint(dbPath)
    if (!fp) return

    const dir = getCacheDir()
    await mkdir(dir, { recursive: true })
    const cache: ResultCache = {
      dbMtimeMs: fp.mtimeMs,
      dbSizeBytes: fp.size,
      calls,
    }
    const finalPath = getCachePath()
    const tmpPath = `${finalPath}.${randomBytes(8).toString('hex')}.tmp`
    const handle = await open(tmpPath, 'w', 0o600)
    try {
      await handle.writeFile(JSON.stringify(cache), { encoding: 'utf-8' })
      await handle.sync()
    } finally {
      await handle.close()
    }
    await rename(tmpPath, finalPath)
  } catch {}
}
