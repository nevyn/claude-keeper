import AppKit

/// Runs the app as LaunchServices launched it. A launch for a link (the `GURL` event arrives before
/// `applicationDidFinishLaunching`) makes this process the router; any other launch shows the setup window. Both
/// handle links, because LaunchServices gives a link to a running Claude Keeper process instead of launching one.
@MainActor
func runApp() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedForLink = false
    private var finishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if launchedForLink {
            MainActor.assumeIsolated { Router.shared.becomeRouterProcess() }
        } else {
            MainActor.assumeIsolated { showSetupWindow() }
        }
    }

    /// The setup window quits with its last window; the router process quits when it has no links left.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !launchedForLink }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else {
            log("error: ignored a GURL event without a URL")
            return
        }
        if !finishedLaunching && !launchedForLink {
            launchedForLink = true
            redirectOutputToLog()
            NSApp.setActivationPolicy(.accessory)  // before Router.open can activate the app for the chooser
        }
        MainActor.assumeIsolated { Router.shared.open(url) }
    }
}

/// Forwards links to instances; see docs/link-routing.md.
@MainActor
final class Router {
    static let shared = Router()

    private var pending = 0
    private var quitsWhenIdle = false

    /// Called once in a process that LaunchServices launched for a link: from now on it quits when no link is pending.
    func becomeRouterProcess() {
        quitsWhenIdle = true
        quitIfIdle()
    }

    /// Routes `url` (see `route`), shows the chooser when the decision is to ask, and forwards it. Opens it with
    /// `Claude.app` instead when link routing is off or anything on the way fails. Links are independent: each one
    /// stays pending until it has been forwarded, opened or dropped.
    func open(_ url: URL) {
        pending += 1
        log("link \(linkSummary(url))")
        guard linkRoutingOn else { return failOpen(url, "link routing is off") }
        let instances = discoverInstances(), running = runningInstances(instances)
        let lastActive = load(LastActive.self, from: lastActiveURL)
        switch route(LinkKind(url), instances: instances.map(\.name), running: running, lastActive: lastActive) {
        case .deliver(let name): forward(url, to: name, pid: running[name]!)
        case .choose(let names, let preselected):
            let choices = names.compactMap { name in instances.first { $0.name == name } }
            Chooser.ask(link: url, instances: choices, preselected: preselected) { picked in
                guard let picked else { log("dropped \(linkSummary(url))"); return self.finish() }
                guard let pid = runningInstances([picked])[picked.name] else { return self.failOpen(url, "\(picked.name) quit while the chooser was up") }
                self.forward(url, to: picked.name, pid: pid)
            }
        case .failOpen(let reason): failOpen(url, reason)
        }
    }

    private func forward(_ url: URL, to name: String, pid: Int32) {
        if automationStatus(pid: pid, ask: false) == errAEEventNotPermitted {
            return failOpen(url, "Automation of Claude is denied; open Claude Keeper to see how to allow it")
        }
        if #available(macOS 14, *), let target = NSRunningApplication(processIdentifier: pid) { NSApp.yieldActivation(to: target) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try sendLink(url, to: pid) }  // blocks up to 10 s while the Automation prompt is up
            DispatchQueue.main.async {
                switch result {
                case .success: log("forwarded \(linkSummary(url)) to \(name)"); self.finish()
                case .failure(let error): self.failOpen(url, "could not forward it to \(name): \(error)")
                }
            }
        }
    }

    private func failOpen(_ url: URL, _ reason: String) {
        log("opening \(linkSummary(url)) with \(claudeBundle): \(reason)")
        openWithClaude(url) { self.finish() }
    }

    private func finish() {
        pending -= 1
        quitIfIdle()
    }

    private func quitIfIdle() {
        if quitsWhenIdle && pending == 0 { DispatchQueue.main.async { if self.pending == 0 { NSApp.terminate(nil) } } }
    }
}
