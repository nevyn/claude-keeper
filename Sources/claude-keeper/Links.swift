import AppKit
import CoreServices

// MARK: - Link routing model (pure, covered by `claude-keeper selftest`); see docs/link-routing.md

let linkScheme = "claude"
let linkRoutingFlag = stateDir + "/link-routing-on"
let lastActiveURL = URL(fileURLWithPath: stateDir + "/last-active.json")

/// Whether the user turned link routing on in the setup window. The agent checks it every tick.
var linkRoutingOn: Bool { FileManager.default.fileExists(atPath: linkRoutingFlag) }

enum LinkKind: Equatable {
    /// Completes a flow that the user started in one instance moments earlier: a magic link, an SSO callback, a
    /// connector sign-in callback (`claude://claude.ai/mcp-auth-callback/...`), or anything on the `login` host.
    case signIn
    case navigation

    init(_ url: URL) {
        let host = url.host?.lowercased()
        let first = url.pathComponents.dropFirst().first
        if host == "login" { self = .signIn }
        else if host == "claude.ai", let first, ["magic-link", "sso-callback", "mcp-auth-callback"].contains(first) { self = .signIn }
        else { self = .navigation }
    }
}

/// The instance that was most recently frontmost. The agent writes it to `lastActiveURL` whenever it changes.
struct LastActive: Codable, Equatable {
    var name: String
    var pid: Int32
    /// Seconds since 1970 when the agent saw this instance frontmost.
    var ts: Double
}

enum RouteDecision: Equatable {
    /// Forward the link to this running instance.
    case deliver(String)
    /// Ask the user. `names` are the running instances in discovery order; `preselected` is the last-active one.
    case choose([String], preselected: String?)
    /// Open the link with `Claude.app` through LaunchServices, which is what happens without link routing.
    case failOpen(String)
}

/// Decides where a link goes.
/// - Parameters:
///   - instances: every instance name in discovery order (the default instance first).
///   - running: the pid of each running instance, by name.
///   - lastActive: what the agent last recorded; ignored unless that pid is still the named instance's process.
func route(_ kind: LinkKind, instances: [String], running: [String: Int32], lastActive: LastActive?) -> RouteDecision {
    let names = instances.filter { running[$0] != nil }
    if names.isEmpty { return .failOpen("no instance is running") }
    let last = lastActive.flatMap { running[$0.name] == $0.pid ? $0.name : nil }
    if names.count == 1 { return .deliver(names[0]) }
    switch kind {
    case .signIn: return last.map { .deliver($0) } ?? .failOpen("no last-active instance for a sign-in link")
    case .navigation: return .choose(names, preselected: last)
    }
}

/// The scheme, host and first path segment of a link, for logs. Sign-in links carry codes in the rest.
func linkSummary(_ url: URL) -> String {
    "\(url.scheme ?? "?")://\(url.host ?? "")\(url.pathComponents.dropFirst().first.map { "/\($0)" } ?? "")"
}

// MARK: - System calls

/// The app that LaunchServices opens `claude://` links with.
func schemeHandler() -> URL? {
    NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(linkScheme)://claude.ai/new")!)
}

/// Makes `app` the scheme's default handler and waits for LaunchServices to confirm. Shows no dialog for a custom
/// scheme. Works without a run loop: the completion arrives on a background queue.
func setSchemeHandler(_ app: URL) throws {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error?
    NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: linkScheme) { failure = $0; done.signal() }
    if done.wait(timeout: .now() + 10) == .timedOut { throw LinkError.timedOut("making \(app.path) the \(linkScheme):// handler") }
    if let failure { throw failure }
}

/// Whether this process may send `GURL` Apple Events to `pid`. With `ask`, shows the Automation prompt if the user
/// has not answered it yet, and blocks until they do. Returns `noErr`, `errAEEventNotPermitted` (-1743, denied),
/// `errAEEventWouldRequireUserConsent` (-1744, not asked yet) or `procNotFound` (-600).
func automationStatus(pid: Int32, ask: Bool) -> OSStatus {
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kInternetEventClass), AEEventID(kAEGetURL), ask)
}

/// Sends `url` to the process `pid` as the Apple Event that LaunchServices would send, which Claude handles as
/// `open-url`. Without an Automation grant this shows the prompt and waits for it, up to the 10 s timeout.
func sendLink(_ url: URL, to pid: Int32) throws {
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: keyDirectObject)
    do { _ = try event.sendEvent(options: [.noReply], timeout: 10) }
    catch { throw LinkError.sendFailed(pid: pid, status: (error as NSError).code) }
}

/// Opens `url` with `Claude.app` through LaunchServices: the behaviour without link routing. Needs no grant, and
/// launches the default instance if nothing is running.
/// - Parameter completion: runs once on the main queue after LaunchServices has answered, whether or not it opened
///   the link; a failure is logged. A router process that quits before then can lose the link.
func openWithClaude(_ url: URL, then completion: @escaping @MainActor () -> Void = {}) {
    NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: claudeBundle), configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if let error { log("error: could not open \(linkSummary(url)) with \(claudeBundle): \(error)") }
        DispatchQueue.main.async { completion() }
    }
}

enum LinkError: Error, CustomStringConvertible {
    case timedOut(String)
    case sendFailed(pid: Int32, status: Int)

    var description: String {
        switch self {
        case .timedOut(let what): "timed out \(what)"
        case .sendFailed(let pid, let status): "sending the link to pid \(pid) failed with \(status)"
        }
    }
}

// MARK: - Self test

func linkSelftest() -> Int {
    var failures = 0
    func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("ok   \(label)") } else { failures += 1; print("FAIL \(label): expected \(expected), got \(got)") }
    }
    let kind = { (s: String) in LinkKind(URL(string: s)!) }
    check("connector sign-in callback is a sign-in link", kind("claude://claude.ai/mcp-auth-callback/sdk?code=x&state=y"), .signIn)
    check("magic link is a sign-in link", kind("claude://claude.ai/magic-link#token"), .signIn)
    check("SSO callback is a sign-in link", kind("claude://claude.ai/sso-callback?code=x"), .signIn)
    check("login host is a sign-in link", kind("claude://login/google-auth?code=x"), .signIn)
    check("conversation is a navigation link", kind("claude://claude.ai/chat/0a1b"), .navigation)
    check("code session is a navigation link", kind("claude://code/continue?session=last"), .navigation)

    let d = defaultName, p = "Claude (Private)", all = [d, p]
    let both: [String: Int32] = [d: 10, p: 20]
    let lastP = LastActive(name: p, pid: 20, ts: 1)
    check("sign-in link goes to the last-active instance", route(.signIn, instances: all, running: both, lastActive: lastP), .deliver(p))
    check("sign-in link ignores a last-active pid that has been replaced",
          route(.signIn, instances: all, running: both, lastActive: LastActive(name: p, pid: 19, ts: 1)), .failOpen("no last-active instance for a sign-in link"))
    check("sign-in link with one instance running goes there", route(.signIn, instances: all, running: [d: 10], lastActive: lastP), .deliver(d))
    check("navigation link asks, last-active preselected", route(.navigation, instances: all, running: both, lastActive: lastP), .choose(all, preselected: p))
    check("navigation link asks with nothing preselected", route(.navigation, instances: all, running: both, lastActive: nil), .choose(all, preselected: nil))
    check("navigation link with one instance running goes there", route(.navigation, instances: all, running: [p: 20], lastActive: nil), .deliver(p))
    check("nothing running fails open", route(.navigation, instances: all, running: [:], lastActive: lastP), .failOpen("no instance is running"))
    check("summary drops the query and the rest of the path", linkSummary(URL(string: "claude://claude.ai/mcp-auth-callback/sdk?code=secret")!), "claude://claude.ai/mcp-auth-callback")

    let describe = { (s: String) in chooserLinkDescription(URL(string: s)!) }
    check("chooser names a conversation", describe("claude://claude.ai/chat/0a1b"), "a conversation")
    check("chooser names a Claude Code session", describe("claude://code/continue?session=last"), "a Claude Code session")
    check("chooser names a project", describe("claude://claude.ai/project/0a1b"), "a project")
    check("chooser falls back to the link summary", describe("claude://claude.ai/settings/connectors?x=1"), "claude://claude.ai/settings")
    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800), size = NSSize(width: 300, height: 150)
    check("chooser opens below and right of the pointer", chooserFrame(size: size, at: NSPoint(x: 100, y: 500), in: screen), NSRect(x: 100, y: 350, width: 300, height: 150))
    check("chooser stays inside the screen", chooserFrame(size: size, at: NSPoint(x: 900, y: 50), in: screen), NSRect(x: 688, y: 12, width: 300, height: 150))
    return failures
}
