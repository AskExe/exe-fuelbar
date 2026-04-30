import { join } from 'path'
import { homedir } from 'os'

/**
 * Shared cache directory resolver. Checks, in order:
 * 1. EXE_FUELBAR_CACHE_DIR (user override)
 * 2. XDG_CACHE_HOME/exe-fuelbar (Linux/NixOS convention)
 * 3. ~/.cache/exe-fuelbar (default)
 */
export function getCacheDir(): string {
  const explicit = process.env['EXE_FUELBAR_CACHE_DIR']
  if (explicit) return explicit

  const xdgCache = process.env['XDG_CACHE_HOME']
  return join(xdgCache || join(homedir(), '.cache'), 'exe-fuelbar')
}
