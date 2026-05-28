import Foundation
import Observation

private let releasesAPI = "https://api.github.com/repos/AskExe/exe-watcher/releases/latest"
private let checkIntervalSeconds: TimeInterval = 2 * 24 * 60 * 60
private let lastCheckKey = "UpdateChecker.lastCheckDate"
private let cachedVersionKey = "UpdateChecker.latestVersion"
private let rateLimitResetKey = "UpdateChecker.rateLimitReset"
private let forceUpdateButtonKey = "UpdateChecker.forceUpdateButton"
private let forceUpdateButtonEnv = "EXE_WATCHER_FORCE_UPDATE_BUTTON"
private let networkTimeoutSeconds: TimeInterval = 5

@MainActor
@Observable
final class UpdateChecker {
    var latestVersion: String?
    var isUpdating = false
    var updateError: String?

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        let current = currentVersion
        let normalizedLatest = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
        let normalizedCurrent = current.hasPrefix("v") ? String(current.dropFirst()) : current
        guard !normalizedCurrent.isEmpty && normalizedCurrent != "dev" else { return false }
        return normalizedLatest.compare(normalizedCurrent, options: .numeric) == .orderedDescending
    }

    var shouldShowUpdateButton: Bool {
        updateAvailable || localUpdateOverrideEnabled
    }

    var localUpdateOverrideEnabled: Bool {
        if UserDefaults.standard.bool(forKey: forceUpdateButtonKey) { return true }
        let raw = ProcessInfo.processInfo.environment[forceUpdateButtonEnv]?.lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    func checkIfNeeded() async {
        let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        if now - lastCheck < checkIntervalSeconds {
            latestVersion = UserDefaults.standard.string(forKey: cachedVersionKey)
            return
        }
        await check()
    }

    func check() async {
        // Rate limit guard: skip if GitHub told us to back off and the reset time hasn't passed.
        let rateLimitReset = UserDefaults.standard.double(forKey: rateLimitResetKey)
        if rateLimitReset > 0 && Date().timeIntervalSince1970 < rateLimitReset {
            let waitMinutes = Int(ceil((rateLimitReset - Date().timeIntervalSince1970) / 60))
            latestVersion = UserDefaults.standard.string(forKey: cachedVersionKey)
            updateError = "Update check rate-limited — will retry in \(waitMinutes)m"
            return
        }

        guard let url = URL(string: releasesAPI) else { return }
        var request = URLRequest(url: url)
        request.setValue("exe-watcher-menubar-updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = networkTimeoutSeconds

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            // Handle GitHub rate limiting (403 with X-RateLimit-Reset header)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 403 {
                if let resetHeader = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
                   let resetTimestamp = Double(resetHeader) {
                    UserDefaults.standard.set(resetTimestamp, forKey: rateLimitResetKey)
                    let waitMinutes = Int(ceil((resetTimestamp - Date().timeIntervalSince1970) / 60))
                    updateError = "GitHub API rate limit reached. Will retry in \(max(1, waitMinutes))m"
                } else {
                    updateError = "Update check rate-limited — will retry later"
                }
                latestVersion = UserDefaults.standard.string(forKey: cachedVersionKey)
                NSLog("Exe Watcher: GitHub API rate limited (403)")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let asset = release.assets.first(where: {
                $0.name.hasPrefix("ExeWatcherMenubar-") && $0.name.hasSuffix(".zip")
            }) else { return }

            // Validate download URL to prevent supply-chain attacks via compromised API responses.
            let allowedPrefixes = ["https://github.com/", "https://objects.githubusercontent.com/"]
            guard allowedPrefixes.contains(where: { asset.browser_download_url.hasPrefix($0) }) else {
                let msg = "Untrusted download URL: \(asset.browser_download_url)"
                NSLog("Exe Watcher: %@", msg)
                updateError = msg
                return
            }

            let version = asset.name
                .replacingOccurrences(of: "ExeWatcherMenubar-", with: "")
                .replacingOccurrences(of: ".zip", with: "")

            latestVersion = version
            updateError = nil
            // Clear any stale rate limit on success
            UserDefaults.standard.removeObject(forKey: rateLimitResetKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            UserDefaults.standard.set(version, forKey: cachedVersionKey)
        } catch let urlError as URLError {
            // Network error (offline, timeout, DNS failure, proxy issues)
            NSLog("Exe Watcher: update check failed (network): \(urlError)")
            latestVersion = UserDefaults.standard.string(forKey: cachedVersionKey)
            updateError = "Offline — update check unavailable"
        } catch {
            NSLog("Exe Watcher: update check failed: \(error)")
            latestVersion = UserDefaults.standard.string(forKey: cachedVersionKey)
            updateError = "Update check failed — tap to retry"
        }
    }

    func performUpdate() {
        guard !isUpdating else { return }
        isUpdating = true
        updateError = nil

        let process = ExeWatcherCLI.makeProcess(subcommand: ["menubar", "--force"])
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        process.terminationHandler = { [weak self] proc in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isUpdating = false
                if proc.terminationStatus != 0 {
                    self.updateError = self.sanitizeUpdateError(stderr, exitCode: proc.terminationStatus)
                    NSLog("Exe Watcher: update failed (exit \(proc.terminationStatus)): \(stderr)")
                } else {
                    self.updateError = nil
                }
            }
        }

        do {
            try process.run()
        } catch {
            isUpdating = false
            updateError = "Could not start updater: \(error.localizedDescription)"
            NSLog("Exe Watcher: update spawn failed: \(error)")
        }
    }

    private func sanitizeUpdateError(_ stderr: String, exitCode: Int32) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? "Update failed (exit \(exitCode))" : trimmed
        if raw.contains("Restored the previous working Exe Watcher Menubar") {
            return "Update failed safely — previous version restored. Retry when ready."
        }
        if raw.count > 140 {
            return String(raw.prefix(137)) + "…"
        }
        return raw
    }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
}
