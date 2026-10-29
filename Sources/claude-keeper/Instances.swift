import AppKit
import CoreServices

// MARK: - Launcher model (pure, covered by `claude-keeper selftest`); see docs/instances.md

let launcherDataDirKey = "ClaudeKeeperDataDir"
let launcherExecutableKey = "ClaudeKeeperExecutable"
let launcherBundleIDPrefix = "dev.nevyn.ClaudeKeeper.instance."
let instancesDataRoot = stateDir + "/instances"
let launcherLabelLength = 8

/// Why a name cannot be used for a new instance. The description is the message that the Add Instance sheet shows.
enum InstanceNameProblem: Error, Equatable, CustomStringConvertible {
    case empty
    case invalidCharacter(Character)
    case noLetterOrDigit
    case tooLong
    /// A launcher or an app with the instance's bundle name already exists.
    case nameTaken(String)
    /// The launcher `by` already keeps its data under `slug`.
    case slugTaken(slug: String, by: String)

    var description: String {
        switch self {
        case .empty: "Type a name for the instance."
        case .invalidCharacter(let c) where c.isNewline || c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }):
            "A name cannot contain line breaks or other control characters."
        case .invalidCharacter(let c): "A name cannot contain “\(c)”."
        case .noLetterOrDigit: "Use at least one letter or digit in the name."
        case .tooLong: "That name is too long for a file name."
        case .nameTaken(let name): "\(name) already exists. Pick a different name."
        case .slugTaken(let slug, let by): "\(by) already keeps its data in “\(slug)”, which this name would share. Pick a different name."
        }
    }
}

/// The colour of the label on a launcher's icon.
enum LabelColor: String, CaseIterable, Identifiable {
    case blue, teal, green, purple, red, graphite
    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .blue: NSColor(srgbRed: 0.04, green: 0.42, blue: 0.86, alpha: 1)
        case .purple: NSColor(srgbRed: 0.50, green: 0.28, blue: 0.80, alpha: 1)
        case .red: NSColor(srgbRed: 0.84, green: 0.19, blue: 0.22, alpha: 1)
        case .teal: NSColor(srgbRed: 0.0, green: 0.52, blue: 0.56, alpha: 1)
        case .green: NSColor(srgbRed: 0.13, green: 0.55, blue: 0.27, alpha: 1)
        case .graphite: NSColor(srgbRed: 0.32, green: 0.33, blue: 0.37, alpha: 1)
        }
    }
}

/// The apps that a new launcher must not collide with, read from `applicationDirs`.
struct ExistingLaunchers: Equatable {
    /// Folded (see `foldedName`) app file names without `.app`, and the `CFBundleName` of each app.
    var names: Set<String> = []
    /// Slug of each Claude Keeper launcher, mapped to that launcher's name.
    var slugs: [String: String] = [:]

    static func current() -> ExistingLaunchers {
        var existing = ExistingLaunchers()
        for dir in applicationDirs {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                let base = (entry as NSString).deletingPathExtension
                existing.names.insert(foldedName(base))
                guard let info = NSDictionary(contentsOfFile: dir + "/" + entry + "/Contents/Info.plist") as? [String: Any] else { continue }
                let name = info["CFBundleName"] as? String ?? base
                existing.names.insert(foldedName(name))
                if let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(launcherBundleIDPrefix) {
                    existing.slugs[String(id.dropFirst(launcherBundleIDPrefix.count))] = name
                }
            }
        }
        return existing
    }
}

/// `name` as APFS compares file names by default: case-insensitive and normalization-insensitive.
func foldedName(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

/// Everything about a launcher that Claude Keeper is about to create.
struct LauncherPlan: Equatable {
    /// What the user typed, trimmed: "Work".
    var name: String
    /// "work"; names the data directory and ends the bundle ID.
    var slug: String
    var label: String
    var color: LabelColor
    /// Where the bundle goes: `<applications>/Claude (Work).app`.
    var bundlePath: String
    var dataDir: String

    var bundleName: String { "Claude (\(name))" }
    var bundleID: String { launcherBundleIDPrefix + slug }
}

/// The data directory's and bundle ID's name for an instance name: lowercase ASCII letters and digits, with a dash
/// between words. Accents are dropped ("Café" is "cafe"); any other letter or digit becomes its code point in hex
/// ("日本" is "u65e5-u672c"). Empty when `name` has no letter or digit.
func instanceSlug(_ name: String) -> String {
    var words: [String] = [], word = ""
    func endWord() { if !word.isEmpty { words.append(word); word = "" } }
    for scalar in name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).unicodeScalars {
        if !CharacterSet.alphanumerics.contains(scalar) { endWord() }
        else if scalar.isASCII { word += String(scalar).lowercased() }
        else { endWord(); words.append("u" + String(scalar.value, radix: 16)) }
    }
    endWord()
    return words.joined(separator: "-")
}

/// The label that the icon shows when the user typed none: the name, uppercased, cut to `launcherLabelLength`.
func defaultInstanceLabel(_ name: String) -> String {
    String(name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(launcherLabelLength))
}

/// Checks `name` and works out where its launcher and data go.
/// - Parameters:
///   - name: what the user typed; surrounding whitespace is ignored.
///   - label: the icon's label as typed; empty means `defaultInstanceLabel(name)`. Cut to `launcherLabelLength`.
///   - applications: the folder that the launcher goes in; see `launcherDirectory()`.
///   - dataRoot: the folder that holds every launcher's data directory; `instancesDataRoot` outside tests.
func launcherPlan(name: String, label: String, color: LabelColor, applications: String, dataRoot: String,
                  existing: ExistingLaunchers) -> Result<LauncherPlan, InstanceNameProblem> {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .failure(.empty) }
    if let bad = name.first(where: { $0 == "/" || $0 == ":" || $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) {
        return .failure(.invalidCharacter(bad))
    }
    let slug = instanceSlug(name)
    guard !slug.isEmpty else { return .failure(.noLetterOrDigit) }
    let typed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let plan = LauncherPlan(name: name, slug: slug, label: typed.isEmpty ? defaultInstanceLabel(name) : String(typed.prefix(launcherLabelLength)),
                            color: color, bundlePath: applications + "/Claude (\(name)).app", dataDir: dataRoot + "/" + slug)
    guard (plan.bundleName + ".app").utf8.count <= Int(NAME_MAX) else { return .failure(.tooLong) }
    if existing.names.contains(foldedName(plan.bundleName)) { return .failure(.nameTaken(plan.bundleName)) }
    if let owner = existing.slugs[slug] { return .failure(.slugTaken(slug: slug, by: owner)) }
    return .success(plan)
}

/// `/Applications` when this user may write to it, else `~/Applications`.
func launcherDirectory() -> String {
    FileManager.default.isWritableFile(atPath: applicationDirs[0]) ? applicationDirs[0] : applicationDirs[1]
}

/// `s` as one `sh` word, in single quotes.
func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// The launcher's executable. It replaces itself with Claude, so no launcher process stays behind and the instance's
/// process is Claude's own binary, which `runningInstances` and ShipIt look for.
func launcherScript(executable: String, dataDir: String) -> String {
    "#!/bin/sh\nexec \(shellQuoted(executable)) \(shellQuoted("--user-data-dir=" + dataDir)) \"$@\"\n"
}

/// The launcher's Info.plist. Copies every `NS*UsageDescription` key and `LSMinimumSystemVersion` from Claude's, so
/// that permission prompts read the same as for the default instance. Declares no URL types: the router owns links.
func launcherInfo(_ plan: LauncherPlan, claudeInfo: [String: Any], executable: String) -> [String: Any] {
    var info: [String: Any] = claudeInfo.filter { $0.key.hasPrefix("NS") && $0.key.hasSuffix("UsageDescription") }
    info.merge([
        "CFBundleIdentifier": plan.bundleID,
        "CFBundleName": plan.bundleName,
        "CFBundleDisplayName": plan.bundleName,
        "CFBundleExecutable": "launcher",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": claudeInfo["LSMinimumSystemVersion"] as? String ?? "13.0",
        launcherDataDirKey: plan.dataDir,
        launcherExecutableKey: executable,
    ]) { _, ours in ours }
    return info
}

// MARK: - Icon

/// Claude's own icon, as `/Applications/Claude.app` names it in `CFBundleIconFile`.
func claudeIcon(bundle: String = claudeBundle) -> NSImage? {
    guard let file = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleIconFile"] as? String else { return nil }
    return NSImage(contentsOfFile: bundle + "/Contents/Resources/" + (file.hasSuffix(".icns") ? file : file + ".icns"))
}

/// `base` at `pixels` × `pixels`, with `label` in a pill of `color` near the bottom; just `base` when `label` is empty.
/// Below 64 px the pill has no text, which would be unreadable there.
func instanceIcon(base: NSImage, label: String, color: LabelColor, pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let s = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .copy, fraction: 1)
    guard !label.isEmpty else { return rep }

    let height = s * 0.2, maxWidth = s * 0.8, padding = height * 0.45
    var font = labelFont(size: height * 0.6)
    var text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
    if text.size().width > maxWidth - 2 * padding {
        font = labelFont(size: font.pointSize * (maxWidth - 2 * padding) / text.size().width)
        text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
    }
    let width = min(maxWidth, max(s * 0.4, text.size().width + 2 * padding))
    let pill = NSRect(x: (s - width) / 2, y: s * 0.12, width: width, height: height)
    let path = NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    shadow.shadowBlurRadius = s * 0.015
    shadow.set()
    color.nsColor.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    path.lineWidth = max(1, s * 0.012)
    path.stroke()
    if pixels >= 64 {
        let size = text.size()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }
    return rep
}

private func labelFont(size: CGFloat) -> NSFont {
    let font = NSFont.systemFont(ofSize: size, weight: .heavy)
    return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
}

/// The point sizes and scales of a macOS app icon, as `iconutil` names them in an iconset.
let iconsetSizes: [(points: Int, scale: Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 1), ($0, 2)] }

/// Writes the launcher's icon to `url` as an .icns, from an iconset that `iconutil` converts.
func writeInstanceIcon(base: NSImage, label: String, color: LabelColor, to url: URL, scratch: URL) throws {
    let iconset = scratch.appendingPathComponent("AppIcon.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (points, scale) in iconsetSizes {
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
        guard let png = instanceIcon(base: base, label: label, color: color, pixels: points * scale)?.representation(using: .png, properties: [:])
        else { throw LauncherError.iconFailed("could not render the \(points * scale) px icon for \(file.path)") }
        try png.write(to: file)
    }
    try run("/usr/bin/iconutil", ["--convert", "icns", iconset.path, "--output", url.path])
}

// MARK: - Making a launcher

enum LauncherError: Error, CustomStringConvertible {
    case claudeMissing(String)
    case exists(String)
    case iconFailed(String)
    case toolFailed(command: String, status: Int32, output: String)
    case registerFailed(path: String, status: OSStatus)

    var description: String {
        switch self {
        case .claudeMissing(let path): "Claude is not installed at \(path)"
        case .exists(let path): "\(path) already exists"
        case .iconFailed(let why): why
        case .toolFailed(let command, let status, let output): "\(command) exited \(status)\(output.isEmpty ? "" : ": \(output)")"
        case .registerFailed(let path, let status): "LaunchServices did not register \(path) (LSRegisterURL returned \(status))"
        }
    }
}

/// Runs `tool` and throws with its combined output when it exits non-zero.
private func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw LauncherError.toolFailed(command: ([tool] + arguments).map { $0.contains(" ") ? shellQuoted($0) : $0 }.joined(separator: " "),
                                       status: process.terminationStatus, output: output)
    }
}

/// Writes the launcher bundle at `plan.bundlePath`, signed ad hoc and verified. Builds it in a scratch folder on the
/// same volume and moves it into place, so a failure leaves no half-made launcher behind. Neither creates the data
/// directory nor registers the bundle with LaunchServices; `installLauncher` does both.
/// - Parameter claude: the Claude bundle whose executable, usage descriptions and icon the launcher uses.
func buildLauncher(_ plan: LauncherPlan, claude: String = claudeBundle) throws {
    let fm = FileManager.default
    guard let claudeInfo = NSDictionary(contentsOfFile: claude + "/Contents/Info.plist") as? [String: Any],
          let executableName = claudeInfo["CFBundleExecutable"] as? String else { throw LauncherError.claudeMissing(claude) }
    guard let icon = claudeIcon(bundle: claude) else { throw LauncherError.iconFailed("could not read Claude's icon from \(claude)/Contents/Resources") }
    let target = URL(fileURLWithPath: plan.bundlePath)
    guard !fm.fileExists(atPath: target.path) else { throw LauncherError.exists(target.path) }
    let folder = target.deletingLastPathComponent()
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
    defer { try? fm.removeItem(at: scratch) }

    let staged = scratch.appendingPathComponent(target.lastPathComponent)
    let contents = staged.appendingPathComponent("Contents")
    for sub in ["MacOS", "Resources"] { try fm.createDirectory(at: contents.appendingPathComponent(sub), withIntermediateDirectories: true) }
    let executable = claude + "/Contents/MacOS/" + executableName
    let info = launcherInfo(plan, claudeInfo: claudeInfo, executable: executable)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let script = contents.appendingPathComponent("MacOS/launcher")
    try Data(launcherScript(executable: executable, dataDir: plan.dataDir).utf8).write(to: script)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try writeInstanceIcon(base: icon, label: plan.label, color: plan.color, to: contents.appendingPathComponent("Resources/AppIcon.icns"), scratch: scratch)
    try run("/usr/bin/codesign", ["--force", "--sign", "-", staged.path])
    try run("/usr/bin/codesign", ["--verify", "--strict", staged.path])
    try fm.moveItem(at: staged, to: target)
}

/// Makes the instance real: creates its data directory, builds its launcher, and registers the launcher with
/// LaunchServices so that Finder, Spotlight and Launchpad show it at once. Keeps a data directory that is already
/// there, which a removed launcher of the same name left.
func installLauncher(_ plan: LauncherPlan) throws {
    try FileManager.default.createDirectory(atPath: plan.dataDir, withIntermediateDirectories: true)
    try buildLauncher(plan)
    let status = LSRegisterURL(URL(fileURLWithPath: plan.bundlePath) as CFURL, true)
    guard status == noErr else { throw LauncherError.registerFailed(path: plan.bundlePath, status: status) }
}

// MARK: - Self test

func instanceSelftest() -> Int {
    var failures = 0
    func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("ok   \(label)") } else { failures += 1; print("FAIL \(label): expected \(expected), got \(got)") }
    }
    check("slug lowercases and joins words with dashes", instanceSlug("  My Work  Stuff "), "my-work-stuff")
    check("slug drops accents", instanceSlug("Café Ünïcode"), "cafe-unicode")
    check("slug spells other letters as code points", instanceSlug("Work 日本"), "work-u65e5-u672c")
    check("slug drops punctuation", instanceSlug("A.B_C (2)!"), "a-b-c-2")
    check("slug of punctuation alone is empty", instanceSlug("!?-"), "")
    check("default label is the name uppercased, cut to 8", defaultInstanceLabel(" Personal stuff"), "PERSONAL")

    let existing = ExistingLaunchers(names: [foldedName("Claude (Private)"), foldedName("Claude")], slugs: ["work": "Claude (Work)"])
    func plan(_ name: String, label: String = "") -> Result<LauncherPlan, InstanceNameProblem> {
        launcherPlan(name: name, label: label, color: .blue, applications: "/Applications", dataRoot: "/data", existing: existing)
    }
    check("plan for a fresh name", plan(" Personal "), .success(LauncherPlan(name: "Personal", slug: "personal", label: "PERSONAL", color: .blue,
                                                                              bundlePath: "/Applications/Claude (Personal).app", dataDir: "/data/personal")))
    check("typed label is kept as typed and cut to 8", (try? plan("Home", label: "Living room").get())?.label, "Living r")
    check("empty name is rejected", plan("   "), .failure(.empty))
    check("slash is rejected", plan("A/B"), .failure(.invalidCharacter("/")))
    check("colon is rejected", plan("A:B"), .failure(.invalidCharacter(":")))
    check("line break is rejected", plan("A\nB"), .failure(.invalidCharacter("\n")))
    check("name without letters or digits is rejected", plan("!!!"), .failure(.noLetterOrDigit))
    check("name of a Parall launcher is rejected, ignoring case", plan("private"), .failure(.nameTaken("Claude (private)")))
    check("name whose slug a launcher uses is rejected", plan("Work!"), .failure(.slugTaken(slug: "work", by: "Claude (Work)")))
    check("name too long for a file name is rejected", plan(String(repeating: "x", count: 250)), .failure(.tooLong))

    let p = try! plan("Personal").get()
    let info = launcherInfo(p, claudeInfo: ["NSCameraUsageDescription": "camera", "CFBundleURLTypes": [1], "LSMinimumSystemVersion": "13.0",
                                            "CFBundleIdentifier": "com.anthropic.claudefordesktop"], executable: claudeExecutable)
    check("launcher Info.plist keys", info.keys.sorted(), [
        "CFBundleDisplayName", "CFBundleExecutable", "CFBundleIconFile", "CFBundleIdentifier", "CFBundleInfoDictionaryVersion", "CFBundleName",
        "CFBundlePackageType", "CFBundleVersion", launcherDataDirKey, launcherExecutableKey, "LSMinimumSystemVersion", "NSCameraUsageDescription",
    ].sorted())
    check("launcher bundle ID", info["CFBundleIdentifier"] as? String, "dev.nevyn.ClaudeKeeper.instance.personal")
    check("launcher Info.plist makes a discoverable instance", launcherInstance(info: info, bundlePath: p.bundlePath).map { [$0.name, $0.userDataDir] },
          ["Claude (Personal)", "/data/personal"])

    let tricky = "/tmp/it's \"a\" $HOME `x` \\ dir"
    let echo = Process(), pipe = Pipe()
    echo.executableURL = URL(fileURLWithPath: "/bin/sh")
    echo.arguments = ["-c", launcherScript(executable: "/bin/echo", dataDir: tricky), "sh", "--extra"]
    echo.standardOutput = pipe
    try? echo.run()
    echo.waitUntilExit()
    check("launcher script passes the data directory and its own arguments through sh unchanged",
          String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "--user-data-dir=\(tricky) --extra\n")

    func procargs(_ argv: [String], _ env: [String]) -> [UInt8] {
        var argc = Int32(argv.count)
        var buf = withUnsafeBytes(of: &argc) { Array($0) } + Array("/exe".utf8) + [0, 0, 0]
        for s in argv + env { buf += Array(s.utf8) + [0] }
        return buf + [0] + Array("executable_path=/exe".utf8) + [0, 0]
    }
    check("procargs parse", parseProcArgs(procargs(["/exe", "--user-data-dir=/d"], ["HOME=/Users/x", "A=b=c"])),
          ProcessArgs(arguments: ["/exe", "--user-data-dir=/d"], environment: ["HOME": "/Users/x", "A": "b=c"]))
    let home = NSHomeDirectory()
    let instances = [Instance(name: defaultName, bundlePath: claudeBundle, userDataDir: nil),
                     Instance(name: "Claude (Work)", bundlePath: "/w", userDataDir: "/data/work"),
                     Instance(name: "Claude (Home)", bundlePath: "/h", userDataDir: nil, home: "/Users/other")]
    func owner(_ argv: [String], _ env: [String: String]) -> String? { instanceName(of: ProcessArgs(arguments: argv, environment: env), among: instances) }
    check("process with a data directory belongs to that instance", owner(["/exe", "--user-data-dir=/data/work"], ["HOME": home]), "Claude (Work)")
    check("process without one belongs to the default instance", owner(["/exe"], ["HOME": home + "/"]), defaultName)
    check("process without HOME belongs to the default instance", owner(["/exe"], [:]), defaultName)
    check("process with another HOME belongs to that HOME-override instance", owner(["/exe"], ["HOME": "/Users/other"]), "Claude (Home)")
    check("process with an unknown HOME belongs to no instance", owner(["/exe"], ["HOME": "/Users/stranger"]), nil)
    check("helper process belongs to no instance", owner(["/exe", "--type=renderer", "--user-data-dir=/data/work"], [:]), nil)
    check("Parall HOME-override launcher is discovered",
          launcherInstance(info: ["ParallAppBundleId": "com.anthropic.claudefordesktop", "ParallDataStorage": "", "ParallHomeDirectory": "/Users/other/",
                                  "CFBundleName": "Claude (Home)"], bundlePath: "/h").map { [$0.home, $0.dataDir] },
          ["/Users/other", "/Users/other/Library/Application Support/Claude"])
    check("Parall launcher with neither a data directory nor a HOME is skipped",
          launcherInstance(info: ["ParallAppBundleId": "com.anthropic.claudefordesktop", "ParallDataStorage": "", "ParallHomeDirectory": ""], bundlePath: "/x") == nil, true)
    return failures
}
