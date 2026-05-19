import Foundation

/// Upper bound on payload + stderr bytes read from the CLI. Real payloads top out near 500 KB
/// (365 days of history with dozens of models); anything larger is pathological and truncating
/// prevents unbounded memory growth. Hard timeout guards against a hung CLI keeping Process and
/// Pipe file descriptors pinned forever.
private let maxPayloadBytes = 20 * 1024 * 1024
private let maxStderrBytes = 256 * 1024
private let spawnTimeoutSeconds: UInt64 = 60
/// Badge-only fetches must tolerate large local session corpora. If this is shorter than the
/// real `status --format menubar-json --period today --provider all --no-optimize` runtime, the
/// always-visible badge keeps showing the last cached value and the popover warns "Data may be
/// stale" until the user manually refreshes through the 60s detail path.
private let badgeTimeoutSeconds: UInt64 = spawnTimeoutSeconds

enum DataClientError: Error {
    case spawn(String)
    case nonZeroExit(code: Int32, stderr: String)
    case decode(Error)
    case timeout(seconds: UInt64 = 60)
    case outputTooLarge
}

extension DataClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .spawn(message):
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.localizedCaseInsensitiveContains("no such file or directory") {
                return "Couldn't launch exe-watcher. Reinstall the CLI or set EXE_WATCHER_BIN to a working binary."
            }
            return cleaned.isEmpty ? "Couldn't launch exe-watcher." : cleaned
        case let .nonZeroExit(code, stderr):
            let cleaned = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 127 || cleaned.localizedCaseInsensitiveContains("exe-watcher: no such file or directory") {
                return "The exe-watcher CLI was not found. Reinstall it (`npm install -g exe-watcher`) or set EXE_WATCHER_BIN."
            }
            if code == 126 {
                return "The exe-watcher CLI exists but isn't executable. Reinstall it or fix its permissions."
            }
            if cleaned.isEmpty {
                return "exe-watcher exited with status \(code)."
            }
            return cleaned
        case .decode:
            return "Watcher couldn't decode the CLI response."
        case let .timeout(seconds):
            return "exe-watcher timed out after \(seconds) seconds. Retry once the machine is idle."
        case .outputTooLarge:
            return "Watcher received an unexpectedly large CLI response and refused to render it."
        }
    }
}

/// Runs the CLI via argv (no shell interpretation). See `ExeWatcherCLI` for why we never route
/// commands through `/bin/zsh -c` anymore.
struct DataClient {
    static func fetch(period: Period, provider: ProviderFilter, includeOptimize: Bool) async throws -> MenubarPayload {
        let timeout = (period == .today && provider == .all && !includeOptimize)
            ? badgeTimeoutSeconds
            : spawnTimeoutSeconds
        let result = try await runCLI(subcommand: subcommand(
            period: period,
            provider: provider,
            includeOptimize: includeOptimize
        ), timeoutSeconds: timeout)
        guard result.exitCode == 0 else {
            throw DataClientError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
        let payload: MenubarPayload
        do {
            payload = try JSONDecoder().decode(MenubarPayload.self, from: result.stdout)
        } catch {
            throw DataClientError.decode(error)
        }

        if let diag = payload.diagnostics, !diag.warnings.isEmpty {
            for warning in diag.warnings {
                NSLog("Exe Watcher CLI warning: %@", warning)
            }
        }

        return payload
    }

    static func subcommand(period: Period, provider: ProviderFilter, includeOptimize: Bool) -> [String] {
        var command = [
            "status",
            "--format", "menubar-json",
            "--period", period.cliArg,
            "--provider", provider.cliArg,
        ]
        if !includeOptimize {
            command.append("--no-optimize")
        }
        return command
    }

    private struct ProcessResult {
        let stdout: Data
        let stderr: String
        let exitCode: Int32
    }

    private static func runCLI(subcommand: [String], timeoutSeconds: UInt64 = spawnTimeoutSeconds) async throws -> ProcessResult {
        let process = ExeWatcherCLI.makeProcess(subcommand: subcommand)
        let timeoutState = TimeoutState()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw DataClientError.spawn(error.localizedDescription)
        }

        // Drain both pipes concurrently so a large stderr can't deadlock stdout (the child
        // blocks on write once the pipe buffer fills). `drain` also enforces a byte cap.
        async let stdoutData = drain(outPipe.fileHandleForReading, limit: maxPayloadBytes)
        async let stderrData = drain(errPipe.fileHandleForReading, limit: maxStderrBytes)

        // Wall-clock timeout: if the CLI hangs (parser stuck, disk stall), kill it.
        let timeoutTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            if process.isRunning {
                timeoutState.markTimedOut()
                process.terminate()
            }
        }
        defer { timeoutTask.cancel() }

        let (out, err) = await (stdoutData, stderrData)
        process.waitUntilExit()

        if timeoutState.read() {
            throw DataClientError.timeout(seconds: timeoutSeconds)
        }

        if out.count >= maxPayloadBytes {
            throw DataClientError.outputTooLarge
        }

        let stderrString = String(data: err, encoding: .utf8) ?? ""
        return ProcessResult(stdout: out, stderr: stderrString, exitCode: process.terminationStatus)
    }

    /// Pulls bytes off a pipe until EOF or `limit`. Intentionally uses `availableData`, which
    /// returns empty on EOF -- no blocking once the child exits.
    private static func drain(_ handle: FileHandle, limit: Int) async -> Data {
        await Task.detached(priority: .utility) {
            var buffer = Data()
            while buffer.count < limit {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let remaining = limit - buffer.count
                if chunk.count > remaining {
                    buffer.append(chunk.prefix(remaining))
                    break
                }
                buffer.append(chunk)
            }
            return buffer
        }.value
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}
