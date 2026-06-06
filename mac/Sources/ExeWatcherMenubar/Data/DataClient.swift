import Foundation
import Darwin

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
    case appTooOld(required: String, current: String)
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
        case let .appTooOld(required, current):
            return "This app (v\(current)) is too old for the installed CLI. Update to v\(required)+ via the menubar or reinstall."
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

        // Version compatibility gate: if the CLI declares a minimum app version that's
        // newer than ours, surface an actionable error instead of rendering stale/broken data.
        if let minRequired = payload.minAppVersion {
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            let normalizedRequired = minRequired.hasPrefix("v") ? String(minRequired.dropFirst()) : minRequired
            let normalizedCurrent = current.hasPrefix("v") ? String(current.dropFirst()) : current
            if !normalizedCurrent.isEmpty
                && normalizedCurrent != "dev"
                && normalizedRequired.compare(normalizedCurrent, options: .numeric) == .orderedDescending
            {
                throw DataClientError.appTooOld(required: normalizedRequired, current: normalizedCurrent)
            }
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
        let tempDir = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let stdoutURL = tempDir.appendingPathComponent("exe-watcher-\(token).stdout")
        let stderrURL = tempDir.appendingPathComponent("exe-watcher-\(token).stderr")

        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw DataClientError.spawn(error.localizedDescription)
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw DataClientError.spawn(error.localizedDescription)
        }

        let didTimeOut = await waitForExitOrTimeout(process, timeoutSeconds: timeoutSeconds)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        if didTimeOut {
            throw DataClientError.timeout(seconds: timeoutSeconds)
        }

        let out = try readFile(stdoutURL, limit: maxPayloadBytes)
        if out.count >= maxPayloadBytes {
            throw DataClientError.outputTooLarge
        }

        let err = try readFile(stderrURL, limit: maxStderrBytes)
        let stderrString = String(data: err, encoding: .utf8) ?? ""
        return ProcessResult(stdout: out, stderr: stderrString, exitCode: process.terminationStatus)
    }

    /// Uses GCD for both exit detection and timeout enforcement. The previous implementation
    /// polled `process.isRunning` with `Task.sleep`, which hangs indefinitely for accessory
    /// apps because Swift's cooperative scheduler freely defers `.sleep` wakeups for
    /// background/LSUIElement processes. `Process.terminationHandler` + `DispatchSourceTimer`
    /// are wall-clock based and fire reliably regardless of app activation state.
    private static func waitForExitOrTimeout(_ process: Process, timeoutSeconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            // Both the termination handler and the timeout can fire — only the first one resumes.
            let resumed = LockedFlag()

            // --- Normal exit path (GCD callback, not Task.sleep) ---
            process.terminationHandler = { _ in
                if resumed.setIfFirst() {
                    continuation.resume(returning: false)
                }
            }

            // --- Timeout path (GCD timer, not Task.sleep) ---
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + Double(timeoutSeconds))
            timer.setEventHandler {
                timer.cancel()
                guard resumed.setIfFirst() else { return }
                process.terminate()
                // Grace period: SIGKILL after 1s if SIGTERM didn't work.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    process.waitUntilExit()
                }
                continuation.resume(returning: true)
            }
            timer.resume()
        }
    }

    /// Thread-safe one-shot flag. Guarantees a `withCheckedContinuation` is resumed exactly once
    /// even when the termination handler and timeout fire on different queues near-simultaneously.
    private final class LockedFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()
        /// Returns `true` on the first call, `false` on all subsequent calls.
        func setIfFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if flag { return false }
            flag = true
            return true
        }
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count < limit {
            let chunk = handle.readData(ofLength: min(64 * 1024, limit - data.count))
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

}
