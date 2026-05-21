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

    /// Redirecting stdout/stderr to temp files avoids the FileHandle.availableData hangs we saw
    /// in the menubar process around day rollover. A child can write freely without filling a
    /// pipe, while the app enforces a hard wall-clock timeout and then reads capped output.
    private static func waitForExitOrTimeout(_ process: Process, timeoutSeconds: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if !process.isRunning {
            process.waitUntilExit()
            return false
        }

        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < terminateDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return true
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
