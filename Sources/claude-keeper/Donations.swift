import AppKit
import SwiftUI

// MARK: - Donation state (pure, covered by `claude-keeper selftest`); see docs/donations.md

let donationURL = URL(string: "https://ko-fi.com/nevynjpg")!
let donationReminderDelay = 14 * 24 * 3600.0  // after setup was first completed
let donationReminderRetry = 3600.0            // before the agent launches the reminder again when it never got on screen
let donationStateURL = URL(fileURLWithPath: stateDir + "/donation.json")

/// Contents of `donation.json`. Times are in seconds since 1970; nil means that it has not happened.
struct DonationState: Codable, Equatable {
    /// When the setup window first saw setup done. Nothing overwrites it.
    var setupCompleted: Double?
    /// When the `donation-reminder` role put its window on screen.
    var reminderShown: Double?
    /// When the user first clicked Donate…, in the setup window or the reminder.
    var donateClicked: Double?

    /// Whether Claude Keeper still asks for a donation: the reminder has not been shown and the user has not clicked
    /// Donate…. While it does, the setup window's footer has a donation line once setup is done.
    var stillAsking: Bool { reminderShown == nil && donateClicked == nil }
}

/// Whether the agent should launch the `donation-reminder` role at `now` (seconds since 1970): `donationReminderDelay`
/// after setup was first completed, and only while Claude Keeper still asks. A completion time in the future means
/// that the clock was set back, and the reminder waits for the clock to catch up.
func donationReminderDue(now: Double, state: DonationState) -> Bool {
    guard state.stillAsking, let completed = state.setupCompleted else { return false }
    return now - completed >= donationReminderDelay
}

func donationSelftest() -> Int {
    var failures = 0
    func check(_ label: String, _ got: Bool, _ expected: Bool) {
        if got == expected { print("ok   \(label)") } else { failures += 1; print("FAIL \(label): expected \(expected), got \(got)") }
    }
    let done = 1_000_000.0, due = done + donationReminderDelay
    check("no donation reminder without a setup completion time", donationReminderDue(now: due, state: DonationState()), false)
    check("no donation reminder before 14 days", donationReminderDue(now: due - 1, state: DonationState(setupCompleted: done)), false)
    check("donation reminder is due 14 days after setup", donationReminderDue(now: due, state: DonationState(setupCompleted: done)), true)
    check("donation reminder is never shown twice", donationReminderDue(now: due + 1, state: DonationState(setupCompleted: done, reminderShown: due)), false)
    check("no donation reminder after Donate…", donationReminderDue(now: due, state: DonationState(setupCompleted: done, donateClicked: done + 60)), false)
    check("a setup completion time in the future postpones the donation reminder",
          donationReminderDue(now: done, state: DonationState(setupCompleted: done + donationReminderDelay)), false)
    check("the footer asks until the reminder is shown", DonationState(setupCompleted: done).stillAsking, true)
    check("the footer stops asking once the reminder is shown", DonationState(setupCompleted: done, reminderShown: due).stillAsking, false)
    check("the footer stops asking after Donate…", DonationState(donateClicked: done).stillAsking, false)
    return failures
}

/// Applies `change` to `donation.json` and saves it if that changed anything. Reads the file first, so that the setup
/// window and the reminder role keep each other's writes.
func updateDonationState(_ change: (inout DonationState) -> Void) {
    let old = load(DonationState.self, from: donationStateURL) ?? DonationState()
    var new = old
    change(&new)
    if new != old { save(new, to: donationStateURL) }
}

/// Opens the Ko-fi page in the default browser and records the click, which ends both asks for a donation.
@MainActor
func donate() {
    if #available(macOS 14, *), let browser = NSWorkspace.shared.urlForApplication(toOpen: donationURL),
       let id = Bundle(url: browser)?.bundleIdentifier {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)  // the reminder role is never active, so it has to hand activation on
    }
    if !NSWorkspace.shared.open(donationURL) { log("error: could not open \(donationURL) in the default browser") }
    updateDonationState { $0.donateClicked = $0.donateClicked ?? Date().timeIntervalSince1970 }
}

// MARK: - The donation-reminder role

/// Shows the donation reminder and quits when the user answers it or closes it. Quits at once if the reminder has
/// already been shown or the user has clicked Donate…. See docs/donations.md.
@MainActor
func runDonationReminder() -> Never {
    if isatty(STDERR_FILENO) == 0 { redirectOutputToLog() }  // LaunchServices points stderr at /dev/null
    let state = load(DonationState.self, from: donationStateURL) ?? DonationState()
    guard state.stillAsking else {
        log("not showing the donation reminder: \(state.reminderShown != nil ? "it has been shown already" : "the user clicked Donate…")")
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let reminder = DonationReminder()
    app.delegate = reminder
    app.run()
    exit(0)
}

@MainActor
final class DonationReminder: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: DonationReminderPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = DonationReminderPanel(donate: { donate(); self.quit("donation reminder: the user clicked Donate…") },
                                          notNow: { self.quit("donation reminder: the user clicked Not Now") })
        self.panel = panel
        panel.delegate = self
        panel.setFrame(centeredFrame(size: panel.frame.size, in: NSScreen.main?.visibleFrame), display: false)
        panel.orderFrontRegardless()  // not makeKey: keystrokes meant for the user's own work would land in the reminder
        guard panel.isVisible else { return quit("error: the donation reminder did not get on screen; the agent tries again in \(Int(donationReminderRetry / 60)) min") }
        updateDonationState { $0.reminderShown = $0.reminderShown ?? Date().timeIntervalSince1970 }
        log("showed the donation reminder")
    }

    func windowWillClose(_ notification: Notification) { quit("donation reminder: the user closed it") }

    private func quit(_ message: String) {
        log(message)
        NSApp.terminate(nil)
    }
}

/// A frame of `size` centered in `visible` (a screen's visible frame), or at the origin without a screen.
func centeredFrame(size: NSSize, in visible: NSRect?) -> NSRect {
    guard let visible else { return NSRect(origin: .zero, size: size) }
    return NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height)
}

struct DonationReminderView: View {
    var donate: () -> Void
    var notNow: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Enjoying Claude Keeper?").font(.headline)
            Text("Claude Keeper has kept your Claudes running for two weeks now. It's free to use, and €20 on Ko-fi is a nice way to say thanks.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: notNow) { Text("Not Now").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button(action: donate) { Text("Donate…").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 20)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .tint(Palette.coral)
    }
}

/// The donation reminder: a panel at normal window level that takes clicks without activating the app, since macOS
/// refuses activation to an app that the agent launched in the background.
final class DonationReminderPanel: NSPanel {
    init(donate: @escaping () -> Void, notNow: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let hosting = FirstClickHostingView(rootView: DonationReminderView(donate: donate, notNow: notNow))
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }
}

/// Acts on a click into a panel that is not key, instead of only making the panel key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Snapshots

/// Renders the donation reminder to `<dir>/donation-reminder-<appearance>.png`, without showing it.
@MainActor
func renderDonationReminderSnapshots(to dir: URL) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let panel = DonationReminderPanel(donate: {}, notNow: {})
        panel.appearance = NSAppearance(named: appearance)
        let view = panel.contentView!
        view.appearance = panel.appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = retinaSnapshot(of: view) else { continue }
        let url = dir.appendingPathComponent("donation-reminder-\(suffix).png")
        do { try rep.representation(using: .png, properties: [:])!.write(to: url); print(url.path) }
        catch { print("error: could not write \(url.path): \(error)") }
    }
}

#Preview("Donation reminder") { DonationReminderView(donate: {}, notNow: {}) }
