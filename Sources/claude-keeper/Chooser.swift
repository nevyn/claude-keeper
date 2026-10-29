import AppKit
import SwiftUI

/// Asks the user which instance opens a link, in a panel at the mouse pointer. See docs/link-routing.md.
@MainActor
enum Chooser {
    private static var showing: ChooserPanel?
    private static var waiting: [() -> Void] = []

    /// Shows the chooser for `link` and calls `completion` once, on the main actor, with the instance that the user
    /// picked, or nil when they pressed Esc or clicked outside the panel (which drops the link).
    ///
    /// The panel lists `instances` in the given order and opens at the mouse pointer with the row named
    /// `preselected` highlighted, or the first row when `preselected` is nil or not listed. Return opens the
    /// highlighted row, Up and Down move the highlight, 1-9 pick a row directly, and clicking a row picks it.
    /// This app is activated while the panel is up, so that the panel gets key events.
    ///
    /// When a chooser is already up, this one waits until that one has been answered: a second panel would take key
    /// status from the first, which counts as a click outside and drops the first link.
    /// - Precondition: `instances` is not empty.
    static func ask(link: URL, instances: [Instance], preselected: String?, completion: @escaping (Instance?) -> Void) {
        precondition(!instances.isEmpty, "the chooser needs at least one instance")
        let present = {
            let panel = ChooserPanel(ChooserModel(link: link, instances: instances, preselected: preselected))
            panel.onAnswer = { picked in
                showing = nil
                completion(picked)
                if !waiting.isEmpty { waiting.removeFirst()() }
            }
            showing = panel
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            panel.setFrame(chooserFrame(size: panel.frame.size, at: mouse, in: screen?.visibleFrame), display: false)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        if showing == nil { present() } else { waiting.append(present) }
    }
}

/// The chooser's frame: its top-left corner at `point`, moved inside `visible` (a screen's visible frame) where it
/// would stick out.
func chooserFrame(size: NSSize, at point: NSPoint, in visible: NSRect?) -> NSRect {
    var frame = NSRect(origin: NSPoint(x: point.x, y: point.y - size.height), size: size)
    guard let visible else { return frame }
    frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size.width))
    frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - size.height))
    return frame
}

/// What the chooser says that a link opens: "a conversation", "a Claude Code session", "a project", or else its
/// `linkSummary`.
func chooserLinkDescription(_ url: URL) -> String {
    let host = url.host?.lowercased(), first = url.pathComponents.dropFirst().first
    if host == "code" { return "a Claude Code session" }
    if host == "claude.ai", first == "chat" { return "a conversation" }
    if host == "claude.ai", first == "project" { return "a project" }
    return linkSummary(url)
}

@MainActor
final class ChooserModel: ObservableObject {
    let link: URL
    let instances: [Instance]
    let icons: [NSImage]
    @Published var highlighted: Int
    /// Called with a row index when the user picks that row; the panel sets it.
    var pick: (Int) -> Void = { _ in }

    init(link: URL, instances: [Instance], preselected: String?) {
        self.link = link
        self.instances = instances
        icons = instances.map { NSWorkspace.shared.icon(forFile: $0.bundlePath) }
        highlighted = preselected.flatMap { name in instances.firstIndex { $0.name == name } } ?? 0
    }

    func move(_ delta: Int) { highlighted = max(0, min(highlighted + delta, instances.count - 1)) }
}

// MARK: - Views

struct ChooserView: View {
    @ObservedObject var model: ChooserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open in which Claude?").font(.headline)
                Text("Link to \(chooserLinkDescription(model.link))")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(model.instances.indices, id: \.self, content: row)
        }
        .padding(10)
        .frame(width: 300)
    }

    private func row(_ i: Int) -> some View {
        let highlighted = i == model.highlighted
        return HStack(spacing: 10) {
            Image(nsImage: model.icons[i]).resizable().frame(width: 28, height: 28)
            Text(model.instances[i].name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if i < 9 {
                Text("\(i + 1)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(highlighted ? Color.white.opacity(0.6) : Color.secondary.opacity(0.5), lineWidth: 1))
            }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { model.highlighted = i } }
        .onTapGesture { model.pick(i) }
    }
}

// MARK: - Panel

final class ChooserPanel: NSPanel {
    let model: ChooserModel
    /// Called once, with the picked instance or nil, when the user answers.
    var onAnswer: (Instance?) -> Void = { _ in }
    private var answered = false

    init(_ model: ChooserModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.maskImage = roundedMask(radius: 12)
        let hosting = NSHostingView(rootView: ChooserView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor), hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        contentView = material
        setContentSize(hosting.fittingSize)
        model.pick = { [unowned self] in answer(self.model.instances[$0]) }
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), handleKey(event) { return }
        super.sendEvent(event)
    }

    /// Losing key status means that the user clicked outside the panel or switched apps.
    override func resignKey() {
        super.resignKey()
        answer(nil)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: model.pick(model.highlighted)  // Return, keypad Enter
        case 53: answer(nil)  // Esc
        case 125: model.move(1)  // Down
        case 126: model.move(-1)  // Up
        default:
            guard let n = event.charactersIgnoringModifiers.flatMap(Int.init), (1...min(9, model.instances.count)).contains(n) else { return false }
            model.pick(n - 1)
        }
        return true
    }

    private func answer(_ picked: Instance?) {
        guard !answered else { return }
        answered = true
        orderOut(nil)
        onAnswer(picked)
    }
}

private func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

// MARK: - Snapshots

/// Renders the chooser in each example state to `<dir>/chooser-<name>-<appearance>.png`, without showing it.
@MainActor
func renderChooserSnapshots(to dir: URL) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let claude = Instance(name: defaultName, bundlePath: claudeBundle, userDataDir: nil)
    let personal = Instance(name: "Claude (Personal)", bundlePath: claudeBundle, userDataDir: "/tmp/claude-personal")
    let work = Instance(name: "Claude (Work)", bundlePath: claudeBundle, userDataDir: "/tmp/claude-work")
    let examples: [(name: String, link: String, instances: [Instance], preselected: String?)] = [
        ("two-preselected", "claude://claude.ai/chat/0a1b", [claude, personal], personal.name),
        ("three", "claude://claude.ai/project/0a1b", [claude, personal, work], nil),
        ("code-session", "claude://code/continue?session=last", [claude, personal], claude.name),
    ]
    for example in examples {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let panel = ChooserPanel(ChooserModel(link: URL(string: example.link)!, instances: example.instances, preselected: example.preselected))
            panel.appearance = NSAppearance(named: appearance)
            let view = panel.contentView!
            view.appearance = panel.appearance
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = dir.appendingPathComponent("chooser-\(example.name)-\(suffix).png")
            do { try rep.representation(using: .png, properties: [:])!.write(to: url); print(url.path) }
            catch { print("error: could not write \(url.path): \(error)") }
        }
    }
}

#Preview("Two instances") {
    ChooserView(model: ChooserModel(link: URL(string: "claude://claude.ai/chat/0a1b")!,
                                    instances: [Instance(name: "Claude", bundlePath: claudeBundle, userDataDir: nil),
                                                Instance(name: "Claude (Personal)", bundlePath: claudeBundle, userDataDir: "/tmp/p")],
                                    preselected: "Claude (Personal)"))
}
