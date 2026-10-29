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
            NSApp.setActivationPolicy(.accessory)
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
        if !finishedLaunching && !launchedForLink { launchedForLink = true; redirectOutputToLog() }
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

    /// Routes `url` (see `route`), shows the chooser when the decision is to ask, and forwards it.
    func open(_ url: URL) {
        pending += 1
        defer { pending -= 1; quitIfIdle() }
        log("link \(linkSummary(url)): failing open, the router is not built yet")
        openWithClaude(url)
    }

    private func quitIfIdle() {
        if quitsWhenIdle && pending == 0 { DispatchQueue.main.async { if self.pending == 0 { NSApp.terminate(nil) } } }
    }
}
