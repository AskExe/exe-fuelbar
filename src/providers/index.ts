import { claude } from './claude.js'
import { codex } from './codex.js'
import { copilot } from './copilot.js'
import { pi, omp } from './pi.js'
import type { Provider, SessionSource } from './types.js'

let cursorProvider: Provider | null = null
let cursorLoadAttempted = false

async function loadCursor(): Promise<Provider | null> {
  if (cursorLoadAttempted) return cursorProvider
  cursorLoadAttempted = true
  try {
    const { cursor } = await import('./cursor.js')
    cursorProvider = cursor
    return cursor
  } catch {
    return null
  }
}

let opencodeProvider: Provider | null = null
let opencodeLoadAttempted = false

let cursorAgentProvider: Provider | null = null
let cursorAgentLoadAttempted = false

async function loadOpenCode(): Promise<Provider | null> {
  if (opencodeLoadAttempted) return opencodeProvider
  opencodeLoadAttempted = true
  try {
    const { opencode } = await import('./opencode.js')
    opencodeProvider = opencode
    return opencode
  } catch {
    return null
  }
}

async function loadCursorAgent(): Promise<Provider | null> {
  if (cursorAgentLoadAttempted) return cursorAgentProvider
  cursorAgentLoadAttempted = true
  try {
    const { cursor_agent } = await import('./cursor-agent.js')
    cursorAgentProvider = cursor_agent
    return cursor_agent
  } catch {
    return null
  }
}

const coreProviders: Provider[] = [claude, codex, copilot, pi, omp]

export async function getAllProviders(): Promise<Provider[]> {
  const [cursor, opencode, cursorAgent] = await Promise.all([loadCursor(), loadOpenCode(), loadCursorAgent()])
  const all = [...coreProviders]
  if (cursor) all.push(cursor)
  if (opencode) all.push(opencode)
  if (cursorAgent) all.push(cursorAgent)
  return all
}

export const providers = coreProviders

/** Warnings from provider discovery (schema issues, timeouts, etc.). */
let _lastDiscoveryWarnings: string[] = []

/** Return warnings from the last discoverAllSessions() call. */
export function getDiscoveryWarnings(): string[] {
  return _lastDiscoveryWarnings
}

const PROVIDER_TIMEOUT_MS = 5_000

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<{ result: T | null; warning: string | null }> {
  return Promise.race([
    promise.then(result => ({ result, warning: null })),
    new Promise<{ result: null; warning: string }>(resolve =>
      setTimeout(() => resolve({ result: null, warning: `Provider "${label}" timed out after ${ms}ms — skipped` }), ms),
    ),
  ])
}

export async function discoverAllSessions(providerFilter?: string): Promise<SessionSource[]> {
  _lastDiscoveryWarnings = []
  const allProviders = await getAllProviders()
  const filtered = providerFilter && providerFilter !== 'all'
    ? allProviders.filter(p => p.name === providerFilter)
    : allProviders

  // Run each provider's discovery with independent timeout (Fix 3)
  const results = await Promise.all(
    filtered.map(async provider => {
      try {
        const { result, warning } = await withTimeout(
          provider.discoverSessions(),
          PROVIDER_TIMEOUT_MS,
          provider.name,
        )
        if (warning) {
          _lastDiscoveryWarnings.push(warning)
          return [] as SessionSource[]
        }
        return result ?? []
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err)
        _lastDiscoveryWarnings.push(`Provider "${provider.name}" discovery failed: ${msg}`)
        return [] as SessionSource[]
      }
    }),
  )

  return results.flat()
}

export async function getProvider(name: string): Promise<Provider | undefined> {
  if (name === 'cursor') {
    const cursor = await loadCursor()
    return cursor ?? undefined
  }
  if (name === 'opencode') {
    const oc = await loadOpenCode()
    return oc ?? undefined
  }
  if (name === 'cursor-agent') {
    const ca = await loadCursorAgent()
    return ca ?? undefined
  }
  return coreProviders.find(p => p.name === name)
}
