import AppKit
import ServiceManagement

/// The LaunchAgent that runs `<bundle executable> run`. SMAppService registers it from the plist in
/// `Contents/Library/LaunchAgents`, and System Settings lists it under Login Items as Claude Keeper.
let agentLabel = "dev.nevyn.ClaudeKeeper.agent"
let agentService = SMAppService.agent(plistName: "\(agentLabel).plist")
let logPath = NSHomeDirectory() + "/Library/Logs/claude-keeper.log"

/// v0.1 installed a bare binary with its own plist in ~/Library/LaunchAgents. It must go before the app's agent
/// starts, or two keepers quit and relaunch the same instances.
enum LegacyAgent {
    static let label = "dev.nevyn.claude-keeper"
    static let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    static var installed: Bool { FileManager.default.fileExists(atPath: plist) }

    static func remove() throws {
        launchctl("bootout", "gui/\(getuid())/\(label)")
        for _ in 0..<20 where launchctl("print", "gui/\(getuid())/\(label)") == 0 { Thread.sleep(forTimeInterval: 0.5) }  // bootout is asynchronous
        for path in [plist, stateDir + "/claude-keeper", stateDir + "/source.sha256"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

@discardableResult
func launchctl(_ arguments: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Restarts the running agent, for example so that it picks up an Accessibility grant: a running agent keeps the
/// answer that it got at launch. Does nothing if the agent is not running. Returns at once: launchd waits up to 10 s
/// before it starts an agent that started less than 10 s ago.
func restartAgent() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

func installAgent() throws {
    if LegacyAgent.installed { try LegacyAgent.remove() }
    try agentService.register()
}

/// Called by the agent once its app is in the Trash. Background Task Management may already have dropped its records
/// by then (unregister fails with "record not found") while launchd keeps the job loaded, retrying a spawn that fails.
func unregisterAfterTrash() -> Never {
    do { try agentService.unregister() } catch { log("Background Task Management could not unregister the agent (\(error)); booting out its launchd job") }
    launchctl("bootout", "gui/\(getuid())/\(agentLabel)")  // ends this process too
    exit(0)
}

func uninstallAgent() throws {
    try agentService.unregister()
    if LegacyAgent.installed { try LegacyAgent.remove() }
}

/// Sends the agent's output to the log, since a plist inside the bundle cannot name a path in the user's home.
func redirectOutputToLog() {
    let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    dup2(fd, STDOUT_FILENO)
    dup2(fd, STDERR_FILENO)
    close(fd)
}

/// Lets the agent follow what happens to its app bundle, so that dragging the app to the Trash uninstalls it and
/// dragging a newer version over it upgrades it. Background Task Management does neither on its own; see docs/app.md.
final class BundleWatch {
    enum Verdict: Equatable { case keepRunning, restart(String), uninstall(String) }

    private let executable: String?
    private let inode: Int?
    private let bookmark: Data?
    private var missingSince: Date?
    private var reportedMove = false

    init() {
        let bundle = Bundle.main.bundleURL
        executable = bundle.pathExtension == "app" ? Bundle.main.executablePath : nil
        inode = executable.flatMap(inodeOf)
        bookmark = try? bundle.bookmarkData()
    }

    func check(now: Date) -> Verdict {
        guard let executable else { return .keepRunning }
        guard let current = inodeOf(executable) else {
            let since = missingSince ?? now
            missingSince = since
            guard now.timeIntervalSince(since) >= 10 else { return .keepRunning }  // Finder removes the old copy before it copies a replacement
            var stale = false
            let moved = bookmark.flatMap { try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale) }
            guard let moved, !moved.path.contains("/.Trash/") else { return .uninstall("\(Bundle.main.bundlePath) was moved to the Trash or deleted") }
            if !reportedMove { reportedMove = true; log("warning: Claude Keeper moved to \(moved.path); open it there to register the keeper again") }
            return .keepRunning
        }
        missingSince = nil
        if current != inode { return .restart("a new version replaced \(Bundle.main.bundlePath)") }
        return .keepRunning
    }
}

func inodeOf(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int }
