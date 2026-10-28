import Foundation

let agentLabel = "dev.nevyn.claude-keeper"
let installedBinary = stateDir + "/claude-keeper"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let logPath = NSHomeDirectory() + "/Library/Logs/claude-keeper.log"

struct InstallError: Error, CustomStringConvertible { var description: String }

@discardableResult
func launchctl(_ arguments: String..., quiet: Bool = true) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = arguments
    if quiet { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func agentLoaded() -> Bool { launchctl("print", "gui/\(getuid())/\(agentLabel)") == 0 }

func unloadAgent() {
    launchctl("bootout", "gui/\(getuid())/\(agentLabel)")
    for _ in 0..<20 where agentLoaded() { Thread.sleep(forTimeInterval: 0.5) }  // bootout is asynchronous
}

/// Copies this binary to `installedBinary` and (re)loads the LaunchAgent that runs it. Safe to re-run;
/// running a newer download's `install` upgrades in place, so an Accessibility grant for that path stays valid.
func install() throws {
    guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { throw InstallError(description: "cannot locate my own executable") }
    let fm = FileManager.default
    try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if me != installedBinary {
        let staged = installedBinary + ".new"
        try? fm.removeItem(atPath: staged)
        try fm.copyItem(atPath: me, toPath: staged)
        guard rename(staged, installedBinary) == 0 else { throw InstallError(description: "cannot move \(staged) into place: \(String(cString: strerror(errno)))") }
    }
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [installedBinary, "run"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: agentPlist), options: .atomic)
    unloadAgent()
    guard launchctl("bootstrap", "gui/\(getuid())", agentPlist, quiet: false) == 0 else { throw InstallError(description: "launchctl bootstrap gui/\(getuid()) \(agentPlist) failed") }
    print("""
        Installed claude-keeper \(version) at \(installedBinary) and loaded LaunchAgent \(agentLabel).
        Log: \(logPath)

        For desktop placement:
        1. Grant \(installedBinary) Accessibility in System Settings > Privacy & Security > Accessibility.
        2. Enable "Switch to Desktop N" for every desktop involved, in System Settings > Keyboard >
           Keyboard Shortcuts > Mission Control.
        """)
}

/// Unloads the LaunchAgent and deletes it and the installed binary. State and log stay.
func uninstall() throws {
    unloadAgent()
    for path in [agentPlist, installedBinary] where FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
    }
    print("Removed \(agentLabel). State in \(stateDir) and the log \(logPath) are left in place.")
}
