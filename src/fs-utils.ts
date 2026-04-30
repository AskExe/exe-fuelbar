import { readFile, stat } from 'fs/promises'
import { readFileSync, statSync, createReadStream, openSync, fstatSync, readSync, closeSync, constants } from 'fs'
import { createInterface } from 'readline'

// Hard cap well below V8's 512 MB string limit even with split('\n') doubling.
// Stream threshold chosen as empirical breakeven between readFile+split peak
// memory and createReadStream+readline overhead for typical session files.
export const MAX_SESSION_FILE_BYTES = 128 * 1024 * 1024
export const STREAM_THRESHOLD_BYTES = 8 * 1024 * 1024

function verbose(): boolean {
  return process.env.EXE_WATCHER_VERBOSE === '1'
}

function warn(msg: string): void {
  if (verbose()) process.stderr.write(`exe-watcher: ${msg}\n`)
}

async function readViaStream(filePath: string): Promise<string> {
  const chunks: string[] = []
  const stream = createReadStream(filePath, { encoding: 'utf-8' })
  const rl = createInterface({ input: stream, crlfDelay: Infinity })
  for await (const line of rl) chunks.push(line)
  return chunks.join('\n')
}

export async function readSessionFile(filePath: string): Promise<string | null> {
  let size: number
  try {
    size = (await stat(filePath)).size
  } catch (err) {
    warn(`stat failed for ${filePath}: ${(err as NodeJS.ErrnoException).code ?? 'unknown'}`)
    return null
  }

  if (size > MAX_SESSION_FILE_BYTES) {
    warn(`skipped oversize file ${filePath} (${size} bytes > cap ${MAX_SESSION_FILE_BYTES})`)
    return null
  }

  try {
    if (size >= STREAM_THRESHOLD_BYTES) return await readViaStream(filePath)
    return await readFile(filePath, 'utf-8')
  } catch (err) {
    warn(`read failed for ${filePath}: ${(err as NodeJS.ErrnoException).code ?? 'unknown'}`)
    return null
  }
}

export function readSessionFileSync(filePath: string): string | null {
  // Use O_NOFOLLOW to avoid TOCTOU symlink swaps between stat and read.
  // Falls back to plain readFileSync on platforms that lack O_NOFOLLOW.
  const O_NOFOLLOW = (constants as Record<string, number>)['O_NOFOLLOW'] ?? 0
  let fd: number
  try {
    fd = openSync(filePath, constants.O_RDONLY | O_NOFOLLOW)
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code ?? 'unknown'
    // ELOOP = tried to open a symlink with O_NOFOLLOW — skip it
    if (code === 'ELOOP') { warn(`skipped symlink ${filePath}`); return null }
    warn(`open failed for ${filePath}: ${code}`)
    return null
  }

  try {
    const size = fstatSync(fd).size
    if (size > MAX_SESSION_FILE_BYTES) {
      warn(`skipped oversize file ${filePath} (${size} bytes > cap ${MAX_SESSION_FILE_BYTES})`)
      return null
    }
    const buf = Buffer.allocUnsafe(size)
    let offset = 0
    while (offset < size) {
      const bytesRead = readSync(fd, buf, offset, size - offset, offset)
      if (bytesRead === 0) break
      offset += bytesRead
    }
    return buf.toString('utf-8', 0, offset)
  } catch (err) {
    warn(`read failed for ${filePath}: ${(err as NodeJS.ErrnoException).code ?? 'unknown'}`)
    return null
  } finally {
    closeSync(fd)
  }
}

export async function* readSessionLines(filePath: string): AsyncGenerator<string> {
  let size: number
  try {
    size = (await stat(filePath)).size
  } catch (err) {
    warn(`stat failed for ${filePath}: ${(err as NodeJS.ErrnoException).code ?? 'unknown'}`)
    return
  }

  if (size > MAX_SESSION_FILE_BYTES) {
    warn(`skipped oversize file ${filePath} (${size} bytes > cap ${MAX_SESSION_FILE_BYTES})`)
    return
  }

  const stream = createReadStream(filePath, { encoding: 'utf-8' })
  const rl = createInterface({ input: stream, crlfDelay: Infinity })
  try {
    for await (const line of rl) yield line
  } catch (err) {
    warn(`stream read failed for ${filePath}: ${(err as NodeJS.ErrnoException).code ?? 'unknown'}`)
  } finally {
    stream.destroy()
  }
}
