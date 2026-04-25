import { execSync } from 'child_process'
import { join } from 'path'

import { describe, it, expect } from 'vitest'

const CLI = join(process.cwd(), 'dist', 'cli.js')

function run(args: string): { stdout: string; stderr: string; status: number } {
  try {
    const stdout = execSync(`node ${CLI} ${args}`, {
      encoding: 'utf-8',
      timeout: 15_000,
      env: { ...process.env, NODE_NO_WARNINGS: '1' },
    })
    return { stdout, stderr: '', status: 0 }
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; status?: number }
    return {
      stdout: e.stdout ?? '',
      stderr: e.stderr ?? '',
      status: e.status ?? 1,
    }
  }
}

describe('exe-fuelbar --version', () => {
  it('outputs a semver version number and exits 0', () => {
    const { stdout, status } = run('--version')
    expect(status).toBe(0)
    expect(stdout.trim()).toMatch(/^\d+\.\d+\.\d+/)
  })
})

describe('exe-fuelbar --help', () => {
  it('outputs usage info with command list and exits 0', () => {
    const { stdout, status } = run('--help')
    expect(status).toBe(0)
    expect(stdout).toContain('Usage:')
    expect(stdout).toContain('exe-fuelbar')
    expect(stdout).toContain('Commands:')
    expect(stdout).toContain('report')
    expect(stdout).toContain('status')
    expect(stdout).toContain('optimize')
    expect(stdout).toContain('currency')
  })
})

describe('exe-fuelbar status', () => {
  it('outputs Today/Month line with cost and exits 0', { timeout: 15_000 }, () => {
    const { stdout, status } = run('status')
    expect(status).toBe(0)
    expect(stdout).toContain('Today')
    expect(stdout).toContain('Month')
    expect(stdout).toMatch(/\$[\d,.]+/)
  })

  it('outputs valid JSON with today/month keys when --format json', { timeout: 15_000 }, () => {
    const { stdout, status } = run('status --format json')
    expect(status).toBe(0)
    const data = JSON.parse(stdout.trim())
    expect(data).toHaveProperty('today')
    expect(data).toHaveProperty('month')
    expect(data).toHaveProperty('currency')
    expect(typeof data.today.cost).toBe('number')
    expect(typeof data.today.calls).toBe('number')
  })

  it('outputs valid menubar JSON with generated key when --format menubar-json', { timeout: 15_000 }, () => {
    const { stdout, status } = run('status --format menubar-json')
    expect(status).toBe(0)
    const data = JSON.parse(stdout.trim())
    expect(data).toHaveProperty('generated')
    expect(data).toHaveProperty('current')
    expect(data.generated).toMatch(/^\d{4}-\d{2}-\d{2}T/)
    expect(typeof data.current.cost).toBe('number')
  })
})

describe('exe-fuelbar report', () => {
  it('outputs valid JSON with generated key when --format json -p today', { timeout: 15_000 }, () => {
    const { stdout, status } = run('report --format json -p today')
    expect(status).toBe(0)
    const data = JSON.parse(stdout.trim())
    expect(data).toHaveProperty('generated')
    expect(data).toHaveProperty('currency')
  })
})

describe('exe-fuelbar optimize', () => {
  it('runs without error and exits 0', { timeout: 15_000 }, () => {
    const { status } = run('optimize')
    expect(status).toBe(0)
  })
})

describe('exe-fuelbar currency', () => {
  it('shows current currency and exits 0', () => {
    const { stdout, status } = run('currency')
    expect(status).toBe(0)
    expect(stdout).toContain('Currency:')
  })
})

describe('exe-fuelbar compare', () => {
  it('shows compare help text when --help and exits 0', () => {
    const { stdout, status } = run('compare --help')
    expect(status).toBe(0)
    expect(stdout).toContain('Compare')
    expect(stdout).toContain('--period')
  })
})

describe('exe-fuelbar unknown command', () => {
  it('exits non-zero for a nonexistent subcommand', () => {
    const { status } = run('nonexistent-command')
    expect(status).not.toBe(0)
  })
})
