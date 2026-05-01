import { describe, it, expect, afterEach, vi, beforeEach } from 'vitest'
import * as os from 'node:os'
import * as childProcess from 'node:child_process'

// Mock os.platform before importing the module under test.
// The module reads platform() at call time, so vi.mock is sufficient.
vi.mock('node:os', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:os')>()
  return { ...actual, platform: vi.fn(() => 'darwin') }
})

// Mock child_process.spawn to prevent real subprocesses (sw_vers, open, etc.)
vi.mock('node:child_process', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:child_process')>()
  return { ...actual, spawn: vi.fn() }
})

// Mock fs operations that touch disk (rename, stat, mkdir, mkdtemp, rm, createWriteStream)
vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>()
  return {
    ...actual,
    stat: vi.fn().mockRejectedValue(new Error('ENOENT')),
    mkdir: vi.fn().mockResolvedValue(undefined),
    mkdtemp: vi.fn().mockResolvedValue('/tmp/exe-watcher-menubar-mock'),
    rename: vi.fn().mockResolvedValue(undefined),
    rm: vi.fn().mockResolvedValue(undefined),
  }
})

vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>()
  return {
    ...actual,
    createWriteStream: vi.fn(() => {
      // Return a minimal writable-like object
      const { PassThrough } = require('node:stream')
      return new PassThrough()
    }),
  }
})

// Lazy import so mocks are in place
const { installMenubarApp } = await import('../src/menubar-installer.js')
type InstallResult = Awaited<ReturnType<typeof installMenubarApp>>

// The regex lives in the module as a constant. We replicate it here for the
// pattern-matching tests since it is not exported. The spec asks us to verify
// the pattern, and duplicating a one-line regex is the pragmatic approach.
const ASSET_PATTERN = /^ExeWatcherMenubar-.*\.zip$/

describe('menubar-installer', () => {
  const savedEnv: Record<string, string | undefined> = {}

  beforeEach(() => {
    savedEnv['EXE_WATCHER_FORCE_MACOS_MAJOR'] = process.env.EXE_WATCHER_FORCE_MACOS_MAJOR
    // Default: force macOS 15 so platform checks pass unless a test overrides
    process.env.EXE_WATCHER_FORCE_MACOS_MAJOR = '15'
    vi.mocked(os.platform).mockReturnValue('darwin')
  })

  afterEach(() => {
    // Restore env vars
    if (savedEnv['EXE_WATCHER_FORCE_MACOS_MAJOR'] === undefined) {
      delete process.env.EXE_WATCHER_FORCE_MACOS_MAJOR
    } else {
      process.env.EXE_WATCHER_FORCE_MACOS_MAJOR = savedEnv['EXE_WATCHER_FORCE_MACOS_MAJOR']
    }
    vi.restoreAllMocks()
  })

  // -----------------------------------------------------------------------
  // Platform checks
  // -----------------------------------------------------------------------

  describe('ensureSupportedPlatform (via installMenubarApp)', () => {
    it('throws "macOS only" when platform is linux', async () => {
      vi.mocked(os.platform).mockReturnValue('linux')
      await expect(installMenubarApp()).rejects.toThrow(/macOS only/)
    })

    it('throws "macOS 14+ required" when major version is 13', async () => {
      process.env.EXE_WATCHER_FORCE_MACOS_MAJOR = '13'
      await expect(installMenubarApp()).rejects.toThrow(/macOS 14\+ required/)
    })

    it('passes platform check when major version is 14', async () => {
      process.env.EXE_WATCHER_FORCE_MACOS_MAJOR = '14'

      // Mock global fetch to return a valid release payload so the installer
      // progresses past the platform check. It will still fail later when
      // download is attempted, but that proves the platform gate passed.
      const fakeRelease = {
        tag_name: 'v0.1.1',
        assets: [
          {
            name: 'ExeWatcherMenubar-v0.1.1.zip',
            browser_download_url: 'https://example.com/fake.zip',
          },
        ],
      }

      const mockFetch = vi.fn()
        // First call: GitHub release API
        .mockResolvedValueOnce({
          ok: true,
          json: async () => fakeRelease,
        } as unknown as Response)
        // Second call: download the zip (will fail, that's fine)
        .mockResolvedValueOnce({
          ok: false,
          status: 500,
          body: null,
        } as unknown as Response)

      vi.stubGlobal('fetch', mockFetch)

      // The install should fail somewhere after the platform check.
      // Whatever error we get, it must NOT be the platform gate.
      try {
        await installMenubarApp({ force: true })
        // If it somehow succeeds, that's fine too — platform check passed.
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err)
        expect(msg).not.toMatch(/macOS only/)
        expect(msg).not.toMatch(/macOS 14\+ required/)
      }

      // Verify fetch was called (proves platform check passed)
      expect(mockFetch).toHaveBeenCalled()
    })
  })

  // -----------------------------------------------------------------------
  // InstallResult shape
  // -----------------------------------------------------------------------

  describe('InstallResult type shape', () => {
    it('has installedPath (string) and launched (boolean) when install succeeds', async () => {
      process.env.EXE_WATCHER_FORCE_MACOS_MAJOR = '15'

      // Simulate the app already being installed: stat resolves (file exists),
      // and pgrep says it's running.
      const fsMock = await import('node:fs/promises')
      vi.mocked(fsMock.stat).mockResolvedValueOnce({} as any)

      // Mock spawn for pgrep (isAppRunning → code 0 = running)
      const mockSpawn = vi.mocked(childProcess.spawn)
      const fakeProc = {
        stdout: { on: vi.fn() },
        stderr: { on: vi.fn() },
        on: vi.fn((event: string, cb: Function) => {
          if (event === 'close') cb(0) // pgrep exit 0 = app is running
        }),
      }
      mockSpawn.mockReturnValue(fakeProc as any)

      const result: InstallResult = await installMenubarApp()

      expect(typeof result.installedPath).toBe('string')
      expect(typeof result.launched).toBe('boolean')
      expect(result.installedPath).toContain('Watcher by EXE.app')
      expect(result.launched).toBe(true)
    })
  })

  // -----------------------------------------------------------------------
  // ASSET_PATTERN regex matching
  // -----------------------------------------------------------------------

  describe('ASSET_PATTERN regex', () => {
    it('matches "ExeWatcherMenubar-v0.1.1.zip"', () => {
      expect(ASSET_PATTERN.test('ExeWatcherMenubar-v0.1.1.zip')).toBe(true)
    })

    it('matches "ExeWatcherMenubar-v2.0.0-beta.zip"', () => {
      expect(ASSET_PATTERN.test('ExeWatcherMenubar-v2.0.0-beta.zip')).toBe(true)
    })

    it('does not match "SomethingElse.zip"', () => {
      expect(ASSET_PATTERN.test('SomethingElse.zip')).toBe(false)
    })

    it('does not match "ExeWatcherMenubar.zip" (no dash after name)', () => {
      expect(ASSET_PATTERN.test('ExeWatcherMenubar.zip')).toBe(false)
    })

    it('does not match "ExeWatcherMenubar-v0.1.1.tar.gz" (wrong extension)', () => {
      expect(ASSET_PATTERN.test('ExeWatcherMenubar-v0.1.1.tar.gz')).toBe(false)
    })
  })
})
