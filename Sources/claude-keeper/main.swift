// claude-keeper: gets every Claude desktop instance through an auto-update, relaunching each
// on the desktop where it was last seen. See README.md.
import AppKit
import Darwin
import IOKit

// MARK: - Decision model (pure, covered by `claude-keeper selftest`)

let defaultName = "Claude"
let idleThreshold = 300.0         // seconds without keyboard or mouse input before the keeper quits an instance
let quietThreshold = 300.0        // seconds an instance's Claude Code sessions must have used no CPU
let requitInterval = 600.0        // wait before asking a refusing instance to quit again, or retrying a failed relaunch
let settleDelay = 10.0            // grace after an install for ShipIt's own relaunch of the default instance
let installTimeout = 180.0        // every instance down this long without an install means ShipIt gave up
let attemptMaxAge = 12 * 3600.0   // an older update-attempt no longer obliges a relaunch

/// Contents of `update-attempt`, which Claude writes into its user-data dir when it quits itself to install an update,
/// and which its next launch consumes. `ts` is in milliseconds.
struct UpdateAttempt: Codable, Equatable { var fromVersion: String; var toVersion: String; var ts: Double }

struct Observation {
    var running: [String: Int32]
    var attempts: [String: UpdateAttempt]
    var installed: String?        // CFBundleShortVersionString of /Applications/Claude.app; nil while ShipIt swaps it
    var idle: Double              // seconds since the last keyboard or mouse input
    var quiet: Set<String>        // instances whose Claude Code sessions have been quiet for `quietThreshold`
    var now: Double
}

enum Action: Equatable {
    case quit([String: Int32])    // so that ShipIt can install; ShipIt waits until no process runs Claude.app's binary
    case relaunch([String])       // the default instance first, since it cannot launch while another instance runs
}

/// Drives an update through to every instance running the new version. ShipIt installs only after every instance
/// has quit, but Claude quits just the instance whose idle timer fired, so the others would hold the update back
/// and leave that instance down. The model quits the rest once the user is idle and their sessions are quiet,
/// then relaunches everything that the update or the keeper quit.
struct UpdateModel: Codable, Equatable {
    var quitByKeeper: [String: Int32] = [:]   // pid the keeper quit, per instance; owed a relaunch
    var lastQuit: Double?
    var allDownSince: Double?
    var installedSince: Double?
    var abandoned: Set<String> = []          // toVersion values that ShipIt never installed
    var relaunchTried: [String: Double] = [:]
    var lastBlocking: UpdateAttempt?

    /// Folds one observation into the model and returns what the keeper must do now, with a line for the log.
    mutating func step(_ o: Observation) -> (action: Action, note: String)? {
        guard let installed = o.installed else { return nil }
        quitByKeeper = quitByKeeper.filter { name, pid in o.running[name].map { $0 == pid } ?? true }
        relaunchTried = relaunchTried.filter { o.running[$0.key] == nil }
        let fresh = o.attempts.filter { o.running[$0.key] == nil && o.now - $0.value.ts / 1000 <= attemptMaxAge }
        let blocking = fresh.filter { $0.value.fromVersion == installed && !abandoned.contains($0.value.toVersion) }
        let owed = Set(fresh.keys).union(quitByKeeper.keys).subtracting(o.running.keys)

        func relaunch(_ names: Set<String>, _ note: String) -> (action: Action, note: String) {
            for name in names { relaunchTried[name] = o.now }
            return (.relaunch(names.sorted { ($0 == defaultName ? "" : $0) < ($1 == defaultName ? "" : $1) }), note)
        }

        if !blocking.isEmpty {
            installedSince = nil
            lastBlocking = blocking.values.min { $0.ts < $1.ts }
            let target = blocking.values.map(\.toVersion).sorted().joined(separator: ", ")
            if o.running.isEmpty {
                let since = allDownSince ?? o.now
                allDownSince = since
                guard o.now - since >= installTimeout else { return nil }
                allDownSince = nil
                abandoned.formUnion(blocking.values.map(\.toVersion))
                lastBlocking = nil
                return relaunch(owed, "error: ShipIt did not install \(target) within \(Int(installTimeout)) s of every instance quitting; relaunching \(owed.sorted()) on \(installed)")
            }
            allDownSince = nil
            guard o.idle >= idleThreshold, o.running.keys.allSatisfy(o.quiet.contains) else { return nil }
            if let last = lastQuit, o.now - last < requitInterval { return nil }
            lastQuit = o.now
            for (name, pid) in o.running { quitByKeeper[name] = pid }
            return (.quit(o.running), "\(blocking.keys.sorted()) quit to install \(target); quitting \(o.running.keys.sorted()) so that it can")
        }
        allDownSince = nil
        lastQuit = nil
        let due = owed.filter { relaunchTried[$0].map { o.now - $0 >= requitInterval } ?? true }
        if owed.isEmpty { lastBlocking = nil }
        guard !due.isEmpty else { installedSince = nil; return nil }
        let since = installedSince ?? o.now
        installedSince = since
        guard o.now - since >= settleDelay else { return nil }
        installedSince = nil
        defer { lastBlocking = nil }
        if let stuck = lastBlocking, stuck.fromVersion == installed {
            return relaunch(due, "\(stuck.toVersion) did not install and its update attempt is gone (still on \(installed)); relaunching \(due.sorted())")
        }
        return relaunch(due, "\(installed) installed; relaunching \(due.sorted())")
    }
}

// MARK: - Instances and processes

struct Instance {
    let name: String
    let bundlePath: String
    let userDataDir: String?      // the `--user-data-dir` argument; nil for the default instance
    var dataDir: String { userDataDir ?? NSHomeDirectory() + "/Library/Application Support/Claude" }

    var updateAttempt: UpdateAttempt? {
        (try? Data(contentsOf: URL(fileURLWithPath: dataDir + "/update-attempt"))).flatMap { try? JSONDecoder().decode(UpdateAttempt.self, from: $0) }
    }
}

let claudeBundle = "/Applications/Claude.app"
let claudeExecutable = claudeBundle + "/Contents/MacOS/Claude"

func discoverInstances() -> [Instance] {
    var found = [Instance(name: defaultName, bundlePath: claudeBundle, userDataDir: nil)]
    let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
    for dir in dirs {
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
            let path = dir + "/" + entry
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                  info["ParallAppBundleId"] as? String == "com.anthropic.claudefordesktop",
                  let dataDir = info["ParallDataStorage"] as? String, !dataDir.isEmpty
            else { continue }
            found.append(Instance(name: (info["CFBundleName"] as? String) ?? entry, bundlePath: path, userDataDir: dataDir))
        }
    }
    return found
}

func installedVersion() -> String? {
    NSDictionary(contentsOfFile: claudeBundle + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
}

func processArguments(_ pid: Int32) -> [String]? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // exec path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

func allPids() -> [Int32] {
    var pids = [Int32](repeating: 0, count: 8192)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
    return pids.prefix(max(0, count)).filter { $0 > 0 }
}

func executablePath(_ pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
}

func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

/// Main process of every running instance, keyed by instance name.
func runningInstances(_ instances: [Instance]) -> [String: Int32] {
    var result: [String: Int32] = [:]
    for pid in allPids() {
        guard executablePath(pid) == claudeExecutable, let args = processArguments(pid),
              !args.contains(where: { $0.hasPrefix("--type=") }) else { continue }
        let dataDir = args.first { $0.hasPrefix("--user-data-dir=") }.map { String($0.dropFirst("--user-data-dir=".count)) }
        if let name = instances.first(where: { $0.userDataDir == dataDir })?.name { result[name] = pid }
    }
    return result
}

/// Seconds since the last keyboard, mouse or trackpad input, including input over Screen Sharing; 0 when unreadable.
func userIdleSeconds() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return 0 }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return ((value as? NSNumber)?.doubleValue ?? 0) / 1e9
}

/// Tracks when each instance's Claude Code sessions last did anything. A session is a `.../claude-code/...` CLI
/// process that the instance spawned, plus the tools it runs. It is active while its transcript keeps changing, or
/// while its processes use more CPU than an idle CLI does (about 1% of a core), which catches long tool runs.
final class SessionActivity {
    struct Session { let id: String; let cpu: Double; let transcriptAge: Double? }
    private var cpu: [Int32: Double] = [:]
    private var transcripts: [String: URL] = [:]
    private(set) var lastActive: [String: Double] = [:]
    private(set) var sessions: [String: [Session]] = [:]
    private let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    func sample(_ running: [String: Int32], now: Double) {
        var children: [Int32: [Int32]] = [:]
        for pid in allPids() { if let info = bsdInfo(pid) { children[Int32(info.pbi_ppid), default: []].append(pid) } }
        func subtree(_ root: Int32) -> [Int32] { [root] + (children[root] ?? []).flatMap(subtree) }
        var next: [Int32: Double] = [:]
        for (name, main) in running {
            var covered = Set<Int32>(), found: [Session] = []
            var latest = lastActive[name] ?? now
            for root in subtree(main) where !covered.contains(root) && (executablePath(root)?.contains("/claude-code/") ?? false) {
                let pids = subtree(root)
                covered.formUnion(pids)
                var used = 0.0
                for pid in pids {
                    var task = proc_taskinfo()
                    let size = Int32(MemoryLayout<proc_taskinfo>.size)
                    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
                    let seconds = Double(task.pti_total_user + task.pti_total_system) * ticksToSeconds
                    next[pid] = seconds
                    used += seconds - (cpu[pid] ?? seconds)   // a process first seen in this sample counts from now
                }
                let id = sessionID(root) ?? "pid \(root)"
                let modified = transcript(id).flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                if used > 0.15 { latest = now }
                if let modified { latest = max(latest, modified.timeIntervalSince1970) }
                found.append(Session(id: id, cpu: used, transcriptAge: modified.map { now - $0.timeIntervalSince1970 }))
            }
            lastActive[name] = latest
            sessions[name] = found
        }
        cpu = next
        lastActive = lastActive.filter { running[$0.key] != nil }
    }

    func quiet(now: Double) -> Set<String> { Set(lastActive.filter { now - $0.value >= quietThreshold }.keys) }

    private func sessionID(_ pid: Int32) -> String? {
        guard let args = processArguments(pid) else { return nil }
        for (i, arg) in args.enumerated() {
            for flag in ["--resume", "--session-id"] {
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
                if arg == flag, i + 1 < args.count { return args[i + 1] }
            }
        }
        return nil
    }

    private func transcript(_ id: String) -> URL? {
        if let url = transcripts[id], FileManager.default.fileExists(atPath: url.path) { return url }
        let projects = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let url = dir.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: url.path) { transcripts[id] = url; return url }
        }
        return nil
    }
}

// MARK: - Desktops (private CGS calls; reading works without any TCC grant)

typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: CGSConnectionID) -> Int
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ wids: CFArray) -> CFArray

let cgs = CGSMainConnectionID()

struct Placement: Codable, Equatable { var spaceID: Int; var desktop: Int }

/// User desktops (not fullscreen spaces) in "Switch to Desktop N" order, across all displays.
func desktops() -> [Int] {
    (CGSCopyManagedDisplaySpaces(cgs) as? [[String: Any]] ?? []).flatMap { display in
        (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }.compactMap { $0["ManagedSpaceID"] as? Int }
    }
}

func placement(ofSpace id: Int) -> Placement? {
    desktops().firstIndex(of: id).map { Placement(spaceID: id, desktop: $0 + 1) }
}

/// Desktop of the largest normal window owned by `pid`.
func windowPlacement(pid: Int32) -> Placement? {
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let candidates = windows.compactMap { w -> (area: Double, id: Int)? in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Double], let width = b["Width"], let height = b["Height"],
              width >= 300, height >= 200, let id = w[kCGWindowNumber as String] as? Int else { return nil }
        return (width * height, id)
    }
    for c in candidates.sorted(by: { $0.area > $1.area }) {
        if let space = (CGSCopySpacesForWindows(cgs, 7, [c.id] as CFArray) as? [Int])?.first, let p = placement(ofSpace: space) {
            return p
        }
    }
    return nil
}

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return (session["CGSSessionScreenIsLocked"] as? Bool ?? false) || !(session[kCGSessionOnConsoleKey as String] as? Bool ?? false)
}

enum SwitchError: Error, CustomStringConvertible {
    case noPostEventAccess, desktopGone(Placement), shortcutMissing(Int), didNotSwitch(Int)
    var description: String {
        switch self {
        case .noPostEventAccess: "no Accessibility grant for \(Bundle.main.bundleURL.pathExtension == "app" ? "Claude Keeper" : CommandLine.arguments[0]); open Claude Keeper, or add it in System Settings > Privacy & Security > Accessibility"
        case .desktopGone(let p): "desktop \(p.desktop) (space \(p.spaceID)) no longer exists"
        case .shortcutMissing(let n): "shortcut 'Switch to Desktop \(n)' is disabled or unset in System Settings > Keyboard > Keyboard Shortcuts > Mission Control"
        case .didNotSwitch(let n): "posted the 'Switch to Desktop \(n)' shortcut but the active space did not change within 3 s"
        }
    }
}

/// The user's "Switch to Desktop N" shortcut, or nil while it is disabled or unset.
func desktopShortcut(_ desktop: Int) -> (key: CGKeyCode, flags: CGEventFlags)? {
    CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
    let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    guard desktop >= 1, desktop <= 16, let entry = hotkeys?[String(117 + desktop)] as? [String: Any], (entry["enabled"] as? Int) == 1,
          let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3, params[1] != 65535
    else { return nil }
    return (CGKeyCode(params[1]), CGEventFlags(rawValue: UInt64(params[2])))
}

/// Switches to the desktop by posting the user's own "Switch to Desktop N" shortcut, then waits until it is active.
func switchTo(_ target: Placement) throws {
    if CGSGetActiveSpace(cgs) == target.spaceID { return }
    guard CGPreflightPostEventAccess() else { throw SwitchError.noPostEventAccess }
    guard let desktop = desktops().firstIndex(of: target.spaceID).map({ $0 + 1 }) else { throw SwitchError.desktopGone(target) }
    guard let shortcut = desktopShortcut(desktop) else { throw SwitchError.shortcutMissing(desktop) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.key, keyDown: down)
        event?.flags = shortcut.flags
        event?.post(tap: .cghidEventTap)
    }
    let deadline = Date() + 3
    while Date() < deadline {
        if CGSGetActiveSpace(cgs) == target.spaceID { Thread.sleep(forTimeInterval: 0.4); return }  // let the slide animation finish
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw SwitchError.didNotSwitch(desktop)
}


// MARK: - Keeper

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

let stateDir = NSHomeDirectory() + "/Library/Application Support/claude-keeper"
let placementsURL = URL(fileURLWithPath: stateDir + "/placements.json")
let modelURL = URL(fileURLWithPath: stateDir + "/update-state.json")

func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) } }

func save<T: Encodable>(_ value: T, to url: URL) {
    do {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    } catch { log("warning: could not save \(url.path): \(error)") }
}

final class Keeper {
    var instances = discoverInstances()
    var model = load(UpdateModel.self, from: modelURL) ?? UpdateModel()
    var placements = load([String: Placement].self, from: placementsURL) ?? [:]
    let activity = SessionActivity()
    var tick = 0

    func run() -> Never {
        log("claude-keeper \(version) watching \(instances.map { "\($0.name) (\($0.bundlePath))" }.joined(separator: ", "))")
        if CGPreflightPostEventAccess() { log("post-event access granted") }
        else { log("warning: \(SwitchError.noPostEventAccess); instances will relaunch on the current desktop") }
        let watch = BundleWatch()
        while true {
            autoreleasepool {  // no run loop drains the pool, so each tick's autoreleased objects would live forever
                switch watch.check(now: Date()) {
                case .keepRunning: break
                case .restart(let why): log("restarting: \(why)"); exit(0)  // launchd's KeepAlive starts the bundle's current executable
                case .uninstall(let why): log("unregistering: \(why)"); unregisterAfterTrash()
                }
                if tick % 60 == 0 { instances = discoverInstances() }
                let now = Date().timeIntervalSince1970
                let running = runningInstances(instances)
                if tick % 5 == 0 { activity.sample(running, now: now); recordPlacements(running) }
                let observation = Observation(
                    running: running,
                    attempts: instances.reduce(into: [:]) { $0[$1.name] = $1.updateAttempt },
                    installed: installedVersion(), idle: userIdleSeconds(), quiet: activity.quiet(now: now), now: now)
                let before = model
                let step = model.step(observation)
                if model != before { save(model, to: modelURL) }
                if let step {
                    log(step.note)
                    switch step.action {
                    case .quit(let targets): quit(targets)
                    case .relaunch(let names): relaunch(names)
                    }
                }
            }
            tick += 1
            Thread.sleep(forTimeInterval: 1)
        }
    }

    func recordPlacements(_ running: [String: Int32]) {
        var changed = false
        for (name, pid) in running {
            if let p = windowPlacement(pid: pid), placements[name] != p { placements[name] = p; changed = true }
        }
        if changed { save(placements, to: placementsURL) }
    }

    /// Quits each instance the way Cmd-Q does, falling back to SIGTERM.
    func quit(_ targets: [String: Int32]) {
        for (name, pid) in targets.sorted(by: { $0.key < $1.key }) {
            if let app = NSRunningApplication(processIdentifier: pid), app.terminate(), waitForExit(pid, timeout: 60) { log("quit \(name) (pid \(pid))"); continue }
            log("warning: \(name) (pid \(pid)) ignored the quit request for 60 s; sending SIGTERM")
            kill(pid, SIGTERM)
            if waitForExit(pid, timeout: 30) { log("quit \(name) (pid \(pid)) with SIGTERM") }
            else { log("error: \(name) (pid \(pid)) is still running 30 s after SIGTERM; the update stays pending") }
        }
    }

    /// Launches each instance on its saved desktop, then returns to the desktop that the user was on. A default
    /// instance that ShipIt relaunched on the wrong desktop is restarted on the right one while it is the only instance.
    /// While the screen is locked, it launches them without switching desktops, since keystrokes would reach the lock screen.
    func relaunch(_ names: [String]) {
        let home = placement(ofSpace: CGSGetActiveSpace(cgs))
        let locked = screenIsLocked()
        if locked { log("screen is locked; relaunching without desktop placement") }
        var canSwitch = !locked
        func go(_ target: Placement?, for name: String) {
            guard canSwitch, let target else { return }
            do { try switchTo(target) }
            catch { canSwitch = false; log("error: cannot move to desktop \(target.desktop) for \(name): \(error)") }
        }
        let running = runningInstances(instances)
        if let pid = running[defaultName], running.count == 1, let target = placements[defaultName],
           let started = bsdInfo(pid)?.pbi_start_tvsec, Date().timeIntervalSince1970 - Double(started) < 120 {
            go(target, for: defaultName)
            if canSwitch, let actual = waitForWindow(pid: pid, timeout: 20), actual.spaceID != target.spaceID {
                log("\(defaultName) opened on desktop \(actual.desktop) instead of \(target.desktop); restarting it there")
                quit([defaultName: pid])
                if runningInstances(instances)[defaultName] == nil { launch(defaultName, locked: false) }
            }
        }
        for name in names where runningInstances(instances)[name] == nil {
            go(placements[name], for: name)
            launch(name, locked: locked)
        }
        if let home { go(home, for: "the return to the starting desktop") }
    }

    /// Launches the instance without activating it, and waits for its window so that it opens on the current desktop.
    /// With `locked`, it waits only for the process, because the window's desktop no longer matters.
    func launch(_ name: String, locked: Bool) {
        guard let instance = instances.first(where: { $0.name == name }) else { log("error: instance \(name) no longer exists"); return }
        let others = runningInstances(instances).keys.filter { $0 != name }
        if name == defaultName && !others.isEmpty {
            log("error: cannot launch \(defaultName) while \(others.sorted()) runs; LaunchServices ignores the request")
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g", instance.bundlePath]
        do { try open.run(); open.waitUntilExit() } catch { log("error: open \(instance.bundlePath): \(error)"); return }
        guard open.terminationStatus == 0 else { log("error: open -n -g \(instance.bundlePath) exited \(open.terminationStatus)"); return }
        let deadline = Date() + 60
        var pid: Int32?
        while Date() < deadline {
            pid = runningInstances(instances)[name]
            if let pid, locked { log("launched \(name) (pid \(pid)) while the screen is locked"); return }
            if let pid, let p = windowPlacement(pid: pid) { log("launched \(name) (pid \(pid)) on desktop \(p.desktop)"); return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if let pid { log("error: \(name) (pid \(pid)) launched but has no window on a desktop after 60 s; its windows: \(windowDiagnostics(pid: pid))") }
        else { log("error: open -n -g \(instance.bundlePath) succeeded but no \(name) process appeared within 60 s") }
    }

    func waitForWindow(pid: Int32, timeout: TimeInterval) -> Placement? {
        let deadline = Date() + timeout
        while Date() < deadline {
            if let p = windowPlacement(pid: pid) { return p }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date() + timeout
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}

func windowDiagnostics(pid: Int32) -> String {
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    guard !mine.isEmpty else { return "none" }
    return mine.map { w in
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let id = w[kCGWindowNumber as String] as? Int ?? 0
        let spaces = CGSCopySpacesForWindows(cgs, 7, [id] as CFArray) as? [Int] ?? []
        return "\(id) layer \(w[kCGWindowLayer as String] ?? "?") \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) onscreen \(w[kCGWindowIsOnscreen as String] ?? false) spaces \(spaces)"
    }.joined(separator: "; ")
}

// MARK: - Self test

func selftest() -> Int32 {
    let d = defaultName, p = "Claude (Private)"
    let from = "3.1", to = "Claude 3.2"
    let attempt = UpdateAttempt(fromVersion: from, toVersion: to, ts: 100_000)
    var failures = 0
    typealias Tick = (now: Double, running: [String: Int32], attempts: [String: UpdateAttempt], installed: String?, idle: Double, quiet: Set<String>)
    func check(_ label: String, _ ticks: [Tick], expect: [(Double, Action)]) {
        var m = UpdateModel()
        let got = ticks.compactMap { t in
            m.step(Observation(running: t.running, attempts: t.attempts, installed: t.installed, idle: t.idle, quiet: t.quiet, now: t.now)).map { (t.now, $0.action) }
        }
        if got.map(\.0) == expect.map(\.0) && got.map(\.1) == expect.map(\.1) { print("ok   \(label)") }
        else { failures += 1; print("FAIL \(label): expected \(expect), got \(got)") }
    }
    let busy: Set<String> = [], quietDefault: Set<String> = [d]
    check("private updates while default is in use, then idle and quiet", [
        (100, [d: 1], [p: attempt], from, 5, busy),
        (200, [d: 1], [p: attempt], from, 400, busy),
        (300, [d: 1], [p: attempt], from, 400, quietDefault),
        (301, [:], [p: attempt], from, 400, []),
        (305, [d: 3], [p: attempt], "3.2", 400, []),
        (315, [d: 3], [p: attempt], "3.2", 400, []),
    ], expect: [(300, .quit([d: 1])), (315, .relaunch([p]))])
    check("ShipIt does not relaunch default either", [
        (300, [d: 1], [p: attempt], from, 400, quietDefault),
        (301, [:], [p: attempt], from, 400, []),
        (305, [:], [p: attempt], "3.2", 400, []),
        (315, [:], [p: attempt], "3.2", 400, []),
    ], expect: [(300, .quit([d: 1])), (315, .relaunch([d, p]))])
    check("install already done when the attempt is first seen", [
        (100, [:], [p: attempt], "3.2", 0, []),
        (102, [d: 3], [p: attempt], "3.2", 0, []),
        (110, [d: 3], [p: attempt], "3.2", 0, []),
    ], expect: [(110, .relaunch([p]))])
    check("bundle unreadable while ShipIt swaps it", [
        (100, [:], [p: attempt], nil, 0, []),
        (110, [:], [p: attempt], nil, 0, []),
        (111, [:], [p: attempt], "3.2", 0, []),
        (121, [:], [p: attempt], "3.2", 0, []),
    ], expect: [(121, .relaunch([p]))])
    check("explicit quit stays quit", [
        (100, [d: 1], [:], from, 400, quietDefault),
        (500, [d: 1], [:], from, 400, quietDefault),
    ], expect: [])
    check("stale attempt is ignored", [
        (100_000 + attemptMaxAge + 1, [d: 1], [p: attempt], from, 400, quietDefault),
    ], expect: [])
    check("instance ignores the quit, asked again after the interval", [
        (300, [d: 1], [p: attempt], from, 400, quietDefault),
        (400, [d: 1], [p: attempt], from, 400, quietDefault),
        (300 + requitInterval, [d: 1], [p: attempt], from, 400, quietDefault),
    ], expect: [(300, .quit([d: 1])), (300 + requitInterval, .quit([d: 1]))])
    check("ShipIt never installs: relaunch on the old version, then stop quitting for that version", [
        (300, [d: 1], [p: attempt], from, 400, quietDefault),
        (301, [:], [p: attempt], from, 400, []),
        (301 + installTimeout, [:], [p: attempt], from, 400, []),
        (500, [d: 2], [:], from, 400, quietDefault),
        (2000, [d: 2], [p: attempt], from, 400, quietDefault),
        (2010, [d: 2], [p: attempt], from, 400, quietDefault),
    ], expect: [(300, .quit([d: 1])), (301 + installTimeout, .relaunch([d, p])), (2010, .relaunch([p]))])
    check("user quits the remaining instance themselves", [
        (100, [d: 1], [p: attempt], from, 5, busy),
        (110, [:], [p: attempt], from, 5, []),
        (112, [d: 3], [p: attempt], "3.2", 5, []),
        (122, [d: 3], [p: attempt], "3.2", 5, []),
    ], expect: [(122, .relaunch([p]))])
    check("failed relaunch is retried after the interval, not every tick", [
        (100, [d: 3], [p: attempt], "3.2", 0, []),
        (110, [d: 3], [p: attempt], "3.2", 0, []),
        (200, [d: 3], [p: attempt], "3.2", 0, []),
        (110 + requitInterval, [d: 3], [p: attempt], "3.2", 0, []),
        (120 + requitInterval, [d: 3], [p: attempt], "3.2", 0, []),
    ], expect: [(110, .relaunch([p])), (120 + requitInterval, .relaunch([p]))])
    do {
        var m = UpdateModel()
        let ticks: [Observation] = [
            Observation(running: [p: 1], attempts: [d: attempt], installed: from, idle: 400, quiet: [p], now: 300),
            Observation(running: [:], attempts: [d: attempt], installed: from, idle: 400, quiet: [], now: 301),
            Observation(running: [d: 2], attempts: [:], installed: from, idle: 400, quiet: [], now: 303),
            Observation(running: [d: 2], attempts: [:], installed: from, idle: 400, quiet: [], now: 313),
        ]
        let notes = ticks.compactMap { m.step($0) }
        let label = "attempt consumed without an install: relaunch, and say it did not install"
        if notes.count == 2, notes[1].action == .relaunch([p]), notes[1].note.contains("did not install") { print("ok   \(label)") }
        else { failures += 1; print("FAIL \(label): got \(notes)") }
    }
    failures += linkSelftest()
    return failures == 0 ? 0 : 1
}

// MARK: - Main

switch CommandLine.arguments.dropFirst().first {
case "selftest": exit(selftest())
case "status":
    let instances = discoverInstances(), running = runningInstances(instances)
    let saved = load([String: Placement].self, from: placementsURL) ?? [:]
    print("installed version: \(installedVersion() ?? "unreadable")")
    print("active desktop: \(placement(ofSpace: CGSGetActiveSpace(cgs)).map { "\($0.desktop)" } ?? "fullscreen space")")
    print("user idle: \(Int(userIdleSeconds())) s")
    print("post-event access (this process): \(CGPreflightPostEventAccess() ? "granted" : "MISSING")")
    for i in instances {
        let window = running[i.name].flatMap { windowPlacement(pid: $0) }.map { "desktop \($0.desktop)" } ?? "-"
        let attempt = i.updateAttempt.map { " update-attempt \($0.fromVersion) -> \($0.toVersion)" } ?? ""
        print("\(i.name): pid \(running[i.name].map(String.init) ?? "not running"), window \(window), saved \(saved[i.name].map { "desktop \($0.desktop)" } ?? "-")\(attempt)")
    }
    let activity = SessionActivity()
    let t0 = Date().timeIntervalSince1970
    activity.sample(running, now: t0)
    Thread.sleep(forTimeInterval: 5)
    activity.sample(running, now: t0 + 5)
    for (name, sessions) in activity.sessions.sorted(by: { $0.key < $1.key }) {
        let newest = sessions.compactMap(\.transcriptAge).min().map { "newest transcript write \(Int($0)) s ago" } ?? "no transcripts"
        print("\(name) sessions (\(sessions.count)), \(newest):")
        for s in sessions {
            print("  \(s.id.prefix(8)): \(String(format: "%.2f", s.cpu)) s CPU in 5 s, transcript \(s.transcriptAge.map { "written \(Int($0)) s ago" } ?? "not found")")
        }
    }
    if let state = try? String(contentsOf: modelURL, encoding: .utf8) { print("update state: \(state)") }
case "switch":
    guard let n = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init), n >= 1, n <= desktops().count else {
        print("usage: claude-keeper switch <desktop 1...\(desktops().count)>"); exit(2)
    }
    do { try switchTo(Placement(spaceID: desktops()[n - 1], desktop: n)); print("on desktop \(n)") } catch { print("error: \(error)"); exit(1) }
case "restore":
    let keeper = Keeper(), names = Array(CommandLine.arguments.dropFirst(2))
    keeper.relaunch(names.isEmpty ? keeper.instances.map(\.name) : names)
case "version", "--version": print(version)
case "run":
    if getppid() == 1 { redirectOutputToLog() }
    Keeper().run()
case "agent":
    do {
        switch CommandLine.arguments.dropFirst(2).first {
        case "on": try installAgent()
        case "off": try uninstallAgent()
        case nil, "status": break
        default: print("usage: claude-keeper agent [on | off | status]"); exit(2)
        }
    } catch { print("error: \(error)"); exit(1) }
    print("agent: \(SetupState.current().agent)\(LegacyAgent.installed ? ", v0.1 agent still installed" : "")")
case "snapshot":
    guard let dir = CommandLine.arguments.dropFirst(2).first else { print("usage: claude-keeper snapshot <directory>"); exit(2) }
    MainActor.assumeIsolated { renderSnapshots(to: URL(fileURLWithPath: dir)) }
case "help", "--help", "-h":
    print("usage: claude-keeper [run | status | agent [on | off] | selftest | switch <n> | restore [instance...] | snapshot <dir> | version]; with no arguments, opens the setup window")
default: MainActor.assumeIsolated { runApp() }
}
