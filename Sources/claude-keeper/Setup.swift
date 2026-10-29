import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

/// Everything that the setup window shows. `SetupState.current()` reads it from the system; previews and
/// snapshots use fixed values.
struct SetupState: Equatable {
    enum Location: Equatable { case applications, elsewhere, translocated }
    enum Agent: Equatable { case off, on, needsApproval }
    enum LinkRouting: Equatable {
        case off, on
        /// Routing is on, but the user has not answered the Automation prompt, or no instance runs to ask it against.
        case needsAutomation(instanceRunning: Bool)
        /// The user denied Claude Keeper the Automation permission for Claude.
        case denied
        /// `automationStatus` returned an unexpected status.
        case failed(OSStatus)
    }

    var location: Location
    var instances: [String]
    var agent: Agent
    var accessibility: Bool
    var desktopCount: Int
    var missingShortcuts: [Int]
    var linkRouting: LinkRouting = .off

    var placementReady: Bool { accessibility && missingShortcuts.isEmpty }
    var done: Bool { agent == .on && placementReady }

    static func current() -> SetupState {
        let bundle = Bundle.main.bundlePath
        let location: Location =
            bundle.contains("/AppTranslocation/") ? .translocated
            : bundle.hasPrefix("/Applications/") || bundle.hasPrefix(NSHomeDirectory() + "/Applications/") ? .applications
            : .elsewhere
        let agent: Agent = switch agentService.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
        let count = desktops().count
        let instances = discoverInstances()
        return SetupState(location: location, instances: instances.map(\.name), agent: agent,
                          accessibility: AXIsProcessTrusted(), desktopCount: count,
                          missingShortcuts: (1...max(1, min(count, 16))).filter { desktopShortcut($0) == nil },
                          linkRouting: linkRoutingState(instances))
    }

    private static func linkRoutingState(_ instances: [Instance]) -> LinkRouting {
        guard linkRoutingOn else { return .off }
        guard let pid = firstRunningInstance(instances) else { return .needsAutomation(instanceRunning: false) }
        switch automationStatus(pid: pid, ask: false) {
        case noErr: return .on
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsAutomation(instanceRunning: true)
        case OSStatus(procNotFound): return .needsAutomation(instanceRunning: false)
        case let status: return .failed(status)
        }
    }
}

/// The main pid of the first running instance in discovery order. The Automation permission is asked against it;
/// TCC keys the grant on Claude's bundle ID, so it covers every instance.
func firstRunningInstance(_ instances: [Instance]) -> Int32? {
    let running = runningInstances(instances)
    return instances.lazy.compactMap { running[$0.name] }.first
}

/// Shows the Automation prompt against the first running instance if the user has not answered it, and blocks until
/// they do.
private func askForAutomation() {
    if let pid = firstRunningInstance(discoverInstances()) { _ = automationStatus(pid: pid, ask: true) }
}

/// Logs `error` in full and returns the message that the link routing step shows.
private func linkRoutingFailure(_ what: String, _ error: Error) -> String {
    log("error: \(what): \(error)")
    return "\(what): \((error as? LinkError)?.description ?? error.localizedDescription)"
}

@MainActor
final class Setup: ObservableObject {
    @Published private(set) var state: SetupState
    @Published var error: String?
    @Published private(set) var linkRoutingError: String?
    @Published private(set) var linkRoutingBusy = false
    private var timer: Timer?
    private var agentHasGrant = false

    init(_ state: SetupState, live: Bool) {
        self.state = state
        guard live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let next = SetupState.current()
        if next != state { state = next }
        if !next.accessibility { agentHasGrant = false }
        if next.accessibility && next.agent == .on && !agentHasGrant {
            restartAgent()  // the agent cannot see a grant made after it started; see docs/app.md
            agentHasGrant = true
        }
    }

    func turnOn() {
        agentHasGrant = state.accessibility
        do { try installAgent(); error = nil } catch { self.error = "Could not turn on the keeper: \(error.localizedDescription)" }
        if agentService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    func turnOff() {
        do { try uninstallAgent(); error = nil } catch { self.error = "Could not turn off the keeper: \(error.localizedDescription)" }
        refresh()
    }

    func turnOnLinkRouting() {
        let app = Bundle.main.bundleURL
        changeLinkRouting {
            do {
                try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: linkRoutingFlag))
            } catch { return linkRoutingFailure("Could not turn on link routing", error) }
            do { try setSchemeHandler(app) } catch { return linkRoutingFailure("Could not make \(app.path) the \(linkScheme):// handler", error) }
            askForAutomation()
            return nil
        }
    }

    func allowLinkRouting() { changeLinkRouting { askForAutomation(); return nil } }

    func turnOffLinkRouting() {
        changeLinkRouting {
            do { if linkRoutingOn { try FileManager.default.removeItem(atPath: linkRoutingFlag) } }
            catch { return linkRoutingFailure("Could not turn off link routing", error) }
            do { try setSchemeHandler(URL(fileURLWithPath: claudeBundle)) }
            catch { return linkRoutingFailure("Could not give \(linkScheme):// links back to \(claudeBundle)", error) }
            return nil
        }
    }

    func openAutomationSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") }

    /// Runs `work` off the main thread, since it waits for LaunchServices or for the user to answer the Automation
    /// prompt. `work` returns the message to show in the link routing step when it fails.
    private func changeLinkRouting(_ work: @escaping @Sendable () -> String?) {
        linkRoutingError = nil
        linkRoutingBusy = true
        Task {
            linkRoutingError = await Task.detached(operation: work).value
            linkRoutingBusy = false
            refresh()
        }
    }

    func allowAccessibility() {
        _ = CGRequestPostEventAccess()  // adds Claude Keeper to the list, so that the user only flips its switch
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openShortcutSettings() { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    private func open(_ url: String) { URL(string: url).map { _ = NSWorkspace.shared.open($0) } }
}

// MARK: - Views

enum Palette {
    static let night = Color(red: 0.07, green: 0.05, blue: 0.17)
    static let violet = Color(red: 0.33, green: 0.15, blue: 0.62)
    static let coral = Color(red: 0.95, green: 0.40, blue: 0.38)
    static let gold = Color(red: 0.98, green: 0.74, blue: 0.40)
    static let cyan = Color(red: 0.45, green: 0.80, blue: 0.95)
}

struct SetupView: View {
    @ObservedObject var setup: Setup
    private var state: SetupState { setup.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                if state.location != .applications { locationBanner } else { steps }
                if let error = setup.error {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .tint(Palette.coral)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Keeper").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Keeps every Claude running through updates, each on its own desktop.")
                    .font(.callout).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 20)
        .background(
            ZStack {
                LinearGradient(colors: [Palette.night, Palette.violet], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Palette.coral.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 280)
                RadialGradient(colors: [Palette.cyan.opacity(0.3), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 260)
            }
            .ignoresSafeArea()  // runs under the transparent title bar
        )
    }

    private var locationBanner: some View {
        StepRow(status: .attention, title: "Move Claude Keeper to Applications",
                detail: state.location == .translocated
                    ? "macOS runs apps straight from Downloads from a temporary copy. Drag Claude Keeper into the Applications folder, then open it from there."
                    : "The keeper runs from wherever the app is. Drag Claude Keeper into the Applications folder, then open it from there.") {
            if state.location == .elsewhere { Button("Show in Finder", action: setup.showInFinder) }
        }
    }

    @ViewBuilder private var steps: some View {
        StepRow(status: state.instances.count >= 2 ? .done : .attention, title: "Claude instances",
                detail: state.instances.count >= 2
                    ? state.instances.joined(separator: ", ")
                    : "Only \(state.instances.first ?? "no Claude") found. Make a second instance with Parall, and the keeper will look after both.") {
            if state.instances.count < 2 { Link("Parall", destination: URL(string: "https://parall.app")!) }
        }
        StepRow(status: state.agent == .on ? .done : state.agent == .needsApproval ? .attention : .todo(2), title: "Background keeper",
                detail: state.agent == .needsApproval
                    ? "Allow Claude Keeper under Allow in the Background, in Login Items."
                    : "Finishes Claude's updates and relaunches every instance that they quit.") {
            switch state.agent {
            case .off: Button("Turn On", action: setup.turnOn).buttonStyle(.borderedProminent)
            case .needsApproval: Button("Open Login Items", action: setup.openLoginItems)
            case .on: EmptyView()
            }
        }
        StepRow(status: state.accessibility ? .done : .todo(3), title: "Accessibility",
                detail: "Lets the keeper switch to an instance's desktop before it relaunches it.") {
            if !state.accessibility { Button("Allow…", action: setup.allowAccessibility).buttonStyle(.borderedProminent) }
        }
        StepRow(status: state.missingShortcuts.isEmpty ? .done : .todo(4), title: "Desktop shortcuts",
                detail: state.missingShortcuts.isEmpty
                    ? "Switch to Desktop 1–\(state.desktopCount) are on."
                    : "Turn on Switch to Desktop \(describe(state.missingShortcuts)) in Keyboard Shortcuts › Mission Control.") {
            if !state.missingShortcuts.isEmpty { Button("Open Settings", action: setup.openShortcutSettings) }
        }
        if state.instances.count >= 2 { linkRoutingStep }
    }

    private var linkRoutingStep: some View {
        let keeperOff = state.agent != .on
        let status: StepStatus = switch state.linkRouting {
        case .off: .todo(5)
        case .on: keeperOff ? .attention : .done
        case .needsAutomation, .denied, .failed: .attention
        }
        let next: String? = switch state.linkRouting {
        case .off: "Needs permission to send links to Claude."
        case .on: keeperOff ? "Turn on the background keeper too, or Claude takes the links back the next time it launches." : nil
        case .needsAutomation(instanceRunning: true): "Allow Claude Keeper to send links to Claude."
        case .needsAutomation(instanceRunning: false): "Open a Claude instance to finish."
        case .denied: "macOS blocks Claude Keeper from sending links; allow it in Privacy & Security › Automation."
        case .failed(let code): "Could not check the permission to send links to Claude (error \(code))."
        }
        let detail = ["Opens each claude:// link in the Claude where it belongs: sign-in links in the one you were just using, others in the one you pick.",
                      setup.linkRoutingError ?? next].compactMap { $0 }.joined(separator: " ")
        return StepRow(status: status, title: "Link routing", detail: detail) { linkRoutingButton.disabled(setup.linkRoutingBusy) }
    }

    @ViewBuilder private var linkRoutingButton: some View {
        switch state.linkRouting {
        case .off: Button("Turn On", action: setup.turnOnLinkRouting).buttonStyle(.borderedProminent)
        case .needsAutomation(instanceRunning: true):
            VStack(alignment: .trailing) { Button("Allow…", action: setup.allowLinkRouting).buttonStyle(.borderedProminent); turnOffButton }
        case .needsAutomation(instanceRunning: false): turnOffButton
        case .denied: VStack(alignment: .trailing) { Button("Open Automation Settings", action: setup.openAutomationSettings); turnOffButton }
        case .on, .failed: turnOffButton
        }
    }

    private var turnOffButton: some View { Button("Turn Off", action: setup.turnOffLinkRouting) }

    private var footer: some View {
        HStack {
            Text(state.done ? "All set. The keeper runs in the background; to uninstall, drag Claude Keeper to the Trash."
                 : "Desktop placement is optional; without it, instances relaunch on the current desktop.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            if state.agent == .on { Button("Uninstall", action: setup.turnOff) }
            Button("Done") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(state.done ? Palette.coral : .gray)
        }
    }

    private func describe(_ desktops: [Int]) -> String {
        let names = desktops.map(String.init)
        return names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

enum StepStatus: Equatable { case done, attention, todo(Int) }

struct StepRow<Accessory: View>: View {
    var status: StepStatus
    var title: String
    var detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            badge.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
        case .attention: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 24)).foregroundStyle(.orange)
        case .todo(let n):
            Text("\(n)").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5))
        }
    }
}

// MARK: - Window

@MainActor
func makeSetupWindow(_ setup: Setup) -> NSWindow {
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.contentView = NSHostingView(rootView: SetupView(setup: setup))
    window.setContentSize(window.contentView!.fittingSize)
    return window
}

/// Without a nib, the app has no main menu, and so no Cmd-Q, Cmd-W or Cmd-H. With `updater`, the application menu has
/// "Check for Updates…", which Sparkle enables while it can check.
@MainActor
func makeMainMenu(updater: SPUStandardUpdaterController?) -> NSMenu {
    func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        items.forEach(item.submenu!.addItem)
        return item
    }
    func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    let checkForUpdates = updater.map { updater in
        let item = item("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)), "")
        item.target = updater
        return item
    }
    let main = NSMenu()
    main.addItem(menu("Claude Keeper", [
        item("About Claude Keeper", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
    ] + [checkForUpdates].compactMap { $0 } + [
        .separator(),
        item("Hide Claude Keeper", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
        .separator(),
        item("Quit Claude Keeper", #selector(NSApplication.terminate(_:)), "q"),
    ]))
    main.addItem(menu("Window", [
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
    ]))
    return main
}

@MainActor
func showSetupWindow() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.mainMenu = makeMainMenu(updater: setupUpdater)
    let window = makeSetupWindow(Setup(.current(), live: true))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
}

// MARK: - Snapshots

extension SetupState {
    static let examples: [(name: String, state: SetupState)] = [
        ("fresh", SetupState(location: .applications, instances: ["Claude", "Claude (Personal)"], agent: .off, accessibility: false, desktopCount: 3, missingShortcuts: [2, 3])),
        ("agent-on", SetupState(location: .applications, instances: ["Claude", "Claude (Personal)"], agent: .on, accessibility: false, desktopCount: 3, missingShortcuts: [2, 3])),
        ("done", SetupState(location: .applications, instances: ["Claude", "Claude (Personal)"], agent: .on, accessibility: true, desktopCount: 3, missingShortcuts: [])),
        ("single-instance", SetupState(location: .applications, instances: ["Claude"], agent: .off, accessibility: false, desktopCount: 1, missingShortcuts: [])),
        ("translocated", SetupState(location: .translocated, instances: ["Claude", "Claude (Personal)"], agent: .off, accessibility: false, desktopCount: 3, missingShortcuts: [2, 3])),
        ("link-routing-off", linkRouting(.off)),
        ("link-routing-on", linkRouting(.on)),
        ("link-routing-keeper-off", linkRouting(.on, agent: .off)),
        ("link-routing-needs-automation", linkRouting(.needsAutomation(instanceRunning: true))),
        ("link-routing-no-instance", linkRouting(.needsAutomation(instanceRunning: false))),
        ("link-routing-denied", linkRouting(.denied)),
    ]

    private static func linkRouting(_ routing: LinkRouting, agent: Agent = .on) -> SetupState {
        SetupState(location: .applications, instances: ["Claude", "Claude (Personal)"], agent: agent, accessibility: true, desktopCount: 3,
                   missingShortcuts: [], linkRouting: routing)
    }
}

/// Draws `view` at twice its size in points, like a Retina screen. An offscreen window draws at 1x.
@MainActor
func retinaSnapshot(of view: NSView) -> NSBitmapImageRep? {
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Renders the setup window in each example state to `<dir>/<name>-<appearance>.png`, without showing it.
@MainActor
func renderSnapshots(to dir: URL) {
    _ = NSApplication.shared
    if let icon = Bundle.main.image(forResource: "AppIcon") { NSApp.applicationIconImage = icon }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, state) in SetupState.examples {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = makeSetupWindow(Setup(state, live: false))
            window.appearance = NSAppearance(named: appearance)
            let view = window.contentView!
            view.appearance = window.appearance
            view.layoutSubtreeIfNeeded()
            guard let rep = retinaSnapshot(of: view) else { continue }
            let url = dir.appendingPathComponent("\(name)-\(suffix).png")
            do { try rep.representation(using: .png, properties: [:])!.write(to: url); print(url.path) }
            catch { print("error: could not write \(url.path): \(error)") }
        }
    }
}

#Preview("Fresh") { SetupView(setup: Setup(SetupState.examples[0].state, live: false)) }
#Preview("Done") { SetupView(setup: Setup(SetupState.examples[2].state, live: false)) }
#Preview("Link routing denied") { SetupView(setup: Setup(SetupState.examples.first { $0.name == "link-routing-denied" }!.state, live: false)) }
