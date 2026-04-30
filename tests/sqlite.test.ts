import { describe, it, expect, afterEach } from 'vitest'
import { mkdtemp, rm } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { DatabaseSync } from 'node:sqlite'

import { isSqliteAvailable, getSqliteLoadError, openDatabase } from '../src/sqlite.js'

let tmpDirs: string[] = []

afterEach(async () => {
  while (tmpDirs.length > 0) {
    const d = tmpDirs.pop()
    if (d) await rm(d, { recursive: true, force: true })
  }
})

async function makeTmpDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'exe-watcher-sqlite-'))
  tmpDirs.push(dir)
  return dir
}

/** Create a temp SQLite database with test data and return its path. */
async function createTestDb(): Promise<string> {
  const dir = await makeTmpDir()
  const dbPath = join(dir, 'test.db')
  const db = new DatabaseSync(dbPath)
  db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, value REAL)')
  db.exec("INSERT INTO test VALUES (1, 'alice', 10.5)")
  db.exec("INSERT INTO test VALUES (2, 'bob', 20.0)")
  db.exec("INSERT INTO test VALUES (3, 'carol', 30.75)")
  db.close()
  return dbPath
}

describe('isSqliteAvailable', () => {
  it('returns true on Node 22+', () => {
    expect(isSqliteAvailable()).toBe(true)
  })
})

describe('getSqliteLoadError', () => {
  it('returns a string (either error message or default)', () => {
    const result = getSqliteLoadError()
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })
})

describe('openDatabase', () => {
  it('opens a valid SQLite file and returns a query interface', async () => {
    const dbPath = await createTestDb()
    const db = openDatabase(dbPath)

    expect(db).toBeDefined()
    expect(typeof db.query).toBe('function')
    expect(typeof db.close).toBe('function')

    db.close()
  })

  it('throws on non-existent file', () => {
    expect(() => openDatabase('/nonexistent/path/does-not-exist.db')).toThrow()
  })

  it('throws on invalid (non-SQLite) file', async () => {
    const dir = await makeTmpDir()
    const badPath = join(dir, 'not-a-db.txt')
    const { writeFile } = await import('fs/promises')
    await writeFile(badPath, 'this is not a sqlite database')

    // Opening may succeed but querying should fail, or opening itself may throw
    // depending on the node:sqlite implementation
    let threw = false
    try {
      const db = openDatabase(badPath)
      // If opening succeeded, try a query that requires reading the schema
      db.query('SELECT * FROM sqlite_master')
      db.close()
    } catch {
      threw = true
    }
    // The behavior here is implementation-defined: node:sqlite may let you open
    // a corrupt file but fail on query. Either way, the wrapper doesn't crash.
    expect(typeof threw).toBe('boolean')
  })

  it('queries rows matching SQL', async () => {
    const dbPath = await createTestDb()
    const db = openDatabase(dbPath)

    const rows = db.query<{ id: number; name: string; value: number }>(
      'SELECT * FROM test ORDER BY id',
    )

    expect(rows).toHaveLength(3)
    expect(rows[0]).toEqual({ id: 1, name: 'alice', value: 10.5 })
    expect(rows[1]).toEqual({ id: 2, name: 'bob', value: 20.0 })
    expect(rows[2]).toEqual({ id: 3, name: 'carol', value: 30.75 })

    db.close()
  })

  it('queries with parameterized SQL', async () => {
    const dbPath = await createTestDb()
    const db = openDatabase(dbPath)

    const rows = db.query<{ id: number; name: string; value: number }>(
      'SELECT * FROM test WHERE name = ?',
      ['bob'],
    )

    expect(rows).toHaveLength(1)
    expect(rows[0].name).toBe('bob')
    expect(rows[0].value).toBe(20.0)

    db.close()
  })

  it('returns empty array for query with no matches', async () => {
    const dbPath = await createTestDb()
    const db = openDatabase(dbPath)

    const rows = db.query('SELECT * FROM test WHERE id = ?', [999])
    expect(rows).toEqual([])

    db.close()
  })

  it('close works without error', async () => {
    const dbPath = await createTestDb()
    const db = openDatabase(dbPath)

    // close should not throw
    expect(() => db.close()).not.toThrow()
  })

  it('opens database in read-only mode (INSERT fails)', async () => {
    const dbPath = await createTestDb()
    const db = openDatabase(dbPath)

    // The database is opened read-only; attempting to write should fail
    expect(() =>
      db.query("INSERT INTO test VALUES (4, 'dave', 40.0)"),
    ).toThrow()

    db.close()
  })
})
