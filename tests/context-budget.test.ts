import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, writeFile, mkdir, rm } from 'fs/promises'
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
  estimateContextBudget,
  discoverProjectCwd,
} from '../src/context-budget.js'

const tmpDirs: string[] = []
let fakeHome: string

beforeEach(async () => {
  fakeHome = await mkdtemp(join(tmpdir(), 'exe-fuelbar-ctx-'))
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

describe('estimateContextBudget', () => {
  it('returns base system tokens when no project path is given', async () => {
    const budget = await estimateContextBudget()
    expect(budget.systemBase).toBe(10400)
    expect(budget.mcpTools.count).toBe(0)
    expect(budget.mcpTools.tokens).toBe(0)
    expect(budget.skills.count).toBe(0)
    expect(budget.skills.tokens).toBe(0)
    expect(budget.memory.count).toBe(0)
    expect(budget.memory.tokens).toBe(0)
    expect(budget.total).toBe(10400)
    expect(budget.modelContext).toBe(1_000_000)
  })

  it('respects custom modelContext parameter', async () => {
    const budget = await estimateContextBudget(undefined, 200_000)
    expect(budget.modelContext).toBe(200_000)
  })

  it('counts MCP servers from home settings.json (5 tools x 400 tokens each)', async () => {
    const claudeDir = join(fakeHome, '.claude')
    await mkdir(claudeDir, { recursive: true })
    const config = {
      mcpServers: {
        'server-a': { command: 'echo' },
        'server-b': { command: 'echo' },
      },
    }
    await writeFile(join(claudeDir, 'settings.json'), JSON.stringify(config))

    const budget = await estimateContextBudget()
    expect(budget.mcpTools.count).toBe(10) // 2 servers x 5 tools
    expect(budget.mcpTools.tokens).toBe(4000) // 10 tools x 400 tokens
  })

  it('counts MCP servers from project .mcp.json', async () => {
    const projectDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-proj-'))
    tmpDirs.push(projectDir)

    const config = {
      mcpServers: {
        'proj-server': { command: 'echo' },
      },
    }
    await writeFile(join(projectDir, '.mcp.json'), JSON.stringify(config))

    const budget = await estimateContextBudget(projectDir)
    expect(budget.mcpTools.count).toBe(5) // 1 server x 5 tools
    expect(budget.mcpTools.tokens).toBe(2000) // 5 x 400
  })

  it('deduplicates MCP servers across config files', async () => {
    const claudeDir = join(fakeHome, '.claude')
    await mkdir(claudeDir, { recursive: true })
    const homeConfig = {
      mcpServers: {
        'shared-server': { command: 'echo' },
      },
    }
    await writeFile(join(claudeDir, 'settings.json'), JSON.stringify(homeConfig))

    const projectDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-proj-'))
    tmpDirs.push(projectDir)
    const projClaudeDir = join(projectDir, '.claude')
    await mkdir(projClaudeDir, { recursive: true })
    const projConfig = {
      mcpServers: {
        'shared-server': { command: 'echo' },
        'unique-server': { command: 'echo' },
      },
    }
    await writeFile(join(projClaudeDir, 'settings.json'), JSON.stringify(projConfig))

    const budget = await estimateContextBudget(projectDir)
    // shared-server counted once, unique-server counted once = 2 servers x 5 = 10 tools
    expect(budget.mcpTools.count).toBe(10)
    expect(budget.mcpTools.tokens).toBe(4000)
  })

  it('counts skills from ~/.claude/skills directories with SKILL.md', async () => {
    const skillsDir = join(fakeHome, '.claude', 'skills')
    await mkdir(join(skillsDir, 'my-skill'), { recursive: true })
    await writeFile(join(skillsDir, 'my-skill', 'SKILL.md'), '# My Skill')
    await mkdir(join(skillsDir, 'another-skill'), { recursive: true })
    await writeFile(join(skillsDir, 'another-skill', 'SKILL.md'), '# Another')

    const budget = await estimateContextBudget()
    expect(budget.skills.count).toBe(2)
    expect(budget.skills.tokens).toBe(160) // 2 x 80
  })

  it('ignores skill dirs without SKILL.md', async () => {
    const skillsDir = join(fakeHome, '.claude', 'skills')
    await mkdir(join(skillsDir, 'no-skill-md'), { recursive: true })
    await writeFile(join(skillsDir, 'no-skill-md', 'README.md'), 'not a skill')

    const budget = await estimateContextBudget()
    expect(budget.skills.count).toBe(0)
  })

  it('adds tokens for CLAUDE.md files (text.length / 4)', async () => {
    const claudeDir = join(fakeHome, '.claude')
    await mkdir(claudeDir, { recursive: true })
    // 400 chars => ceil(400/4) = 100 tokens
    const content = 'x'.repeat(400)
    await writeFile(join(claudeDir, 'CLAUDE.md'), content)

    const budget = await estimateContextBudget()
    expect(budget.memory.count).toBe(1)
    expect(budget.memory.tokens).toBe(100)
    expect(budget.memory.files[0].name).toBe('~/.claude/CLAUDE.md')
    expect(budget.memory.files[0].tokens).toBe(100)
  })

  it('includes project CLAUDE.md files', async () => {
    const projectDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-proj-'))
    tmpDirs.push(projectDir)

    // 200 chars => ceil(200/4) = 50 tokens
    await writeFile(join(projectDir, 'CLAUDE.md'), 'y'.repeat(200))

    const budget = await estimateContextBudget(projectDir)
    const projFile = budget.memory.files.find(f => f.name === 'CLAUDE.md')
    expect(projFile).toBeDefined()
    expect(projFile!.tokens).toBe(50)
  })

  it('sums total correctly across all sources', async () => {
    const claudeDir = join(fakeHome, '.claude')
    await mkdir(claudeDir, { recursive: true })

    // 1 MCP server => 5 tools => 2000 tokens
    await writeFile(join(claudeDir, 'settings.json'), JSON.stringify({
      mcpServers: { 'one-server': { command: 'echo' } },
    }))

    // 1 skill => 80 tokens
    const skillsDir = join(claudeDir, 'skills')
    await mkdir(join(skillsDir, 'sk1'), { recursive: true })
    await writeFile(join(skillsDir, 'sk1', 'SKILL.md'), '# Skill')

    // 40 chars => 10 tokens
    await writeFile(join(claudeDir, 'CLAUDE.md'), 'z'.repeat(40))

    const budget = await estimateContextBudget()
    expect(budget.total).toBe(10400 + 2000 + 80 + 10)
  })
})

describe('discoverProjectCwd', () => {
  it('returns cwd from the first jsonl line with a cwd field', async () => {
    const sessionDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-sess-'))
    tmpDirs.push(sessionDir)

    const lines = [
      JSON.stringify({ type: 'init', cwd: '/home/user/project' }),
      JSON.stringify({ type: 'message', text: 'hello' }),
    ].join('\n')
    await writeFile(join(sessionDir, 'session.jsonl'), lines)

    const result = await discoverProjectCwd(sessionDir)
    expect(result).toBe('/home/user/project')
  })

  it('returns null for an empty directory', async () => {
    const sessionDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-sess-'))
    tmpDirs.push(sessionDir)

    const result = await discoverProjectCwd(sessionDir)
    expect(result).toBeNull()
  })

  it('returns null for jsonl with no cwd field', async () => {
    const sessionDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-sess-'))
    tmpDirs.push(sessionDir)

    const lines = [
      JSON.stringify({ type: 'message', text: 'hello' }),
      JSON.stringify({ type: 'response', text: 'world' }),
    ].join('\n')
    await writeFile(join(sessionDir, 'data.jsonl'), lines)

    const result = await discoverProjectCwd(sessionDir)
    expect(result).toBeNull()
  })

  it('returns null for a non-existent directory', async () => {
    const result = await discoverProjectCwd('/nonexistent/dir/xyz')
    expect(result).toBeNull()
  })

  it('skips non-jsonl files and reads only .jsonl', async () => {
    const sessionDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-sess-'))
    tmpDirs.push(sessionDir)

    // A .txt file with cwd should be ignored
    await writeFile(join(sessionDir, 'data.txt'), JSON.stringify({ cwd: '/ignored' }))

    const result = await discoverProjectCwd(sessionDir)
    expect(result).toBeNull()
  })

  it('handles malformed JSON lines gracefully', async () => {
    const sessionDir = await mkdtemp(join(tmpdir(), 'exe-fuelbar-sess-'))
    tmpDirs.push(sessionDir)

    const lines = [
      'not valid json',
      JSON.stringify({ cwd: '/valid/path' }),
    ].join('\n')
    await writeFile(join(sessionDir, 'session.jsonl'), lines)

    const result = await discoverProjectCwd(sessionDir)
    expect(result).toBe('/valid/path')
  })
})
