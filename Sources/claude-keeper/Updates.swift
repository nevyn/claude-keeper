import AppKit
import Sparkle

// MARK: - Update check schedule (pure, covered by `claude-keeper selftest`); see docs/updates.md

let updateCheckDelay = 3600.0          // seconds after the agent starts before its first update check
let updateCheckInterval = 24 * 3600.0  // between update checks, across agent restarts
let updateCheckTimeout = 600.0         // the check-for-updates role quits after this long, whatever Sparkle is doing
let lastUpdateCheckURL = URL(fileURLWithPath: stateDir + "/last-update-check.json")

/// When an agent last launched the `check-for-updates` role, in seconds since 1970.
struct LastUpdateCheck: Codable, Equatable { var ts: Double }

/// Whether the agent should launch an update check at `now`. `started` is when this agent process started, and `last`
/// is when any agent last launched one; all are seconds since 1970. A `last` in the future means that the clock was
/// set back, so it counts as overdue rather than postponing checks until the clock catches up.
func updateCheckDue(now: Double, started: Double, last: Double?) -> Bool {
    guard now - started >= updateCheckDelay else { return false }
    guard let last, last <= now else { return true }
    return now - last >= updateCheckInterval
}

func updateSelftest() -> Int {
    var failures = 0
    func check(_ label: String, _ got: Bool, _ expected: Bool) {
        if got == expected { print("ok   \(label)") } else { failures += 1; print("FAIL \(label): expected \(expected), got \(got)") }
    }
    let start = 1_000_000.0, day = updateCheckInterval
    check("no update check in the agent's first hour", updateCheckDue(now: start + updateCheckDelay - 1, started: start, last: nil), false)
    check("first update check an hour after the agent starts", updateCheckDue(now: start + updateCheckDelay, started: start, last: nil), true)
    check("a restarted agent waits a day after the previous check",
          updateCheckDue(now: start + updateCheckDelay, started: start, last: start - day + updateCheckDelay + 1), false)
    check("update check is due a day after the previous one", updateCheckDue(now: start + day, started: start, last: start), true)
    check("a restarted agent still waits an hour when a check is overdue", updateCheckDue(now: start + 60, started: start, last: start - 2 * day), false)
    check("a previous check in the future counts as overdue", updateCheckDue(now: start + updateCheckDelay, started: start, last: start + day), true)
    return failures
}

// MARK: - Agent side

/// Launches `bundle` through LaunchServices in the `check-for-updates` role, without activating it. The agent cannot
/// run Sparkle itself: it has no run loop, and launchd starts it outside LaunchServices.
func launchUpdateCheck(_ bundle: URL) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-n", "-a", bundle.path, "--args", "check-for-updates"]
    do { try open.run(); open.waitUntilExit() } catch { log("error: could not run /usr/bin/open to check for updates: \(error)"); return }
    if open.terminationStatus == 0 { log("launched an update check") }
    else { log("error: open -g -n -a \(bundle.path) --args check-for-updates exited \(open.terminationStatus); trying again in \(Int(updateCheckInterval / 3600)) h") }
}

// MARK: - The check-for-updates role

/// Checks for an update in the background and quits when Sparkle is done. An update that Sparkle downloads installs
/// as this process quits, without relaunching the app. Logs every outcome. See docs/updates.md.
@MainActor
func runUpdateCheck() -> Never {
    if isatty(STDERR_FILENO) == 0 { redirectOutputToLog() }  // LaunchServices points stderr at /dev/null
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let check = UpdateCheck()
    app.delegate = check
    app.run()
    exit(0)
}

final class UpdateCheck: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: self)
        self.updater = updater
        do { try updater.start() } catch { return quit("error: Sparkle could not start in \(bundle.bundlePath): \(error)") }
        log("checking for an update to \(claude_keeper.version) at \(updater.feedURL?.absoluteString ?? "no feed URL")")
        updater.checkForUpdatesInBackground()  // before Sparkle's own scheduler runs, which then sees a session in progress
        DispatchQueue.main.asyncAfter(deadline: .now() + updateCheckTimeout) {
            self.quit("error: the update check was still running after \(Int(updateCheckTimeout)) s; quitting")
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("found update \(item.displayVersionString) (\(item.fileURL?.absoluteString ?? "no download URL"))")
    }

    /// Declines the immediate-installation block, which relaunches the app and so opens the setup window. Sparkle
    /// installs the update when this process quits instead, which it does when the update cycle finishes.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log("downloaded update \(item.displayVersionString); it installs as the update check quits")
        return false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error = error as NSError? else { return quit("update check finished") }
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { return quit("no update: \(claude_keeper.version) is the newest version") }
        quit("error: the update check failed: \(error)")
    }

    private func quit(_ message: String) {
        log(message)
        NSApp.terminate(nil)
    }
}

// MARK: - Setup window

/// The setup window's updater, for "Check for Updates…". Sparkle also runs its own scheduled checks while the window
/// is open. Nil outside an app bundle, where Sparkle has no feed to read and would show an error at launch.
@MainActor
let setupUpdater: SPUStandardUpdaterController? = Bundle.main.bundleURL.pathExtension == "app"
    ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
