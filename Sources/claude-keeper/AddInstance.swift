import AppKit
import SwiftUI

/// The Add Instance sheet's state: what the user typed, the plan it makes, and how creating it went.
@MainActor
final class AddInstance: ObservableObject, Identifiable {
    @Published var name = ""
    @Published var label = "" { didSet { if label.count > launcherLabelLength { label = String(label.prefix(launcherLabelLength)) } } }
    @Published var color = LabelColor.blue
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    let existing: ExistingLaunchers
    let applications: String
    let baseIcon: NSImage
    private let finished: () -> Void

    /// - Parameter finished: called on the main actor once the sheet should close, after Cancel or a created launcher.
    init(existing: ExistingLaunchers, applications: String, baseIcon: NSImage, error: String? = nil, finished: @escaping () -> Void = {}) {
        self.existing = existing
        self.applications = applications
        self.baseIcon = baseIcon
        self.error = error
        self.finished = finished
    }

    var plan: Result<LauncherPlan, InstanceNameProblem> {
        launcherPlan(name: name, label: label, color: color, applications: applications, dataRoot: instancesDataRoot, existing: existing)
    }

    /// The problem to show under the name field; none while the field is empty.
    var problem: InstanceNameProblem? {
        if case .failure(let problem) = plan, problem != .empty { return problem }
        return nil
    }

    var defaultLabel: String { defaultInstanceLabel(name) }

    func preview(pixels: Int) -> NSImage {
        let label = (try? plan.get())?.label ?? (label.isEmpty ? defaultLabel : label)
        guard let rep = instanceIcon(base: baseIcon, label: label, color: color, pixels: pixels) else { return baseIcon }
        let image = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        image.addRepresentation(rep)
        return image
    }

    func cancel() { finished() }

    /// Builds and registers the launcher off the main thread, then opens it so that the user can sign in.
    func create() {
        guard case .success(let plan) = plan, !busy else { return }
        busy = true
        error = nil
        Task {
            let result = await Task.detached { Result { try installLauncher(plan) } }.value
            busy = false
            switch result {
            case .success:
                log("created \(plan.bundlePath) with data in \(plan.dataDir)")
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: plan.bundlePath), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { log("error: could not open \(plan.bundlePath): \(error)") }
                }
                finished()
            case .failure(let failure):
                let detail = (failure as? LauncherError)?.description ?? "\(failure)"
                log("error: could not create \(plan.bundlePath): \(detail)")
                error = "Could not make \(plan.bundleName): \(detail)"
            }
        }
    }
}

struct AddInstanceView: View {
    @ObservedObject var model: AddInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Claude instance").font(.title3.bold())
                Text("Makes a Claude app with its own data, so that you can sign it in to a different account.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: model.preview(pixels: 256)).resizable().frame(width: 112, height: 112).padding(.top, -6)
                form
            }
            Text("The app goes in \(model.applications) as Claude (\(appName)). Dragging it to the Trash keeps its data, and making one with the same name again picks the data up.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Create", action: model.create).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled((try? model.plan.get()) == nil || model.busy)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Palette.coral)
        .disabled(model.busy)
    }

    private var appName: String {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Name" : name
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("Name:").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $model.name, prompt: Text("Work, Personal…")).labelsHidden()
                    if let problem = model.problem {
                        Text(problem.description).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                Text("Label:")
                TextField("Label", text: $model.label, prompt: Text(model.defaultLabel.isEmpty ? "On the icon" : model.defaultLabel)).labelsHidden()
            }
            GridRow(alignment: .center) {
                Text("Colour:")
                HStack(spacing: 4) { ForEach(LabelColor.allCases, content: swatch) }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
    }

    private func swatch(_ color: LabelColor) -> some View {
        let picked = color == model.color
        return Circle().fill(Color(nsColor: color.nsColor)).frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Color.primary.opacity(picked ? 0.75 : 0), lineWidth: 2).padding(-4))
            .padding(5)
            .contentShape(Circle())
            .onTapGesture { model.color = color }
            .accessibilityElement()
            .accessibilityLabel(color.rawValue.capitalized)
            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Snapshots

/// Renders the Add Instance sheet, rendered launcher icons, and a sample launcher bundle into `dir`, without showing
/// anything or registering the bundle.
@MainActor
func renderAddInstanceSnapshots(to dir: URL) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let base = claudeIcon() ?? NSWorkspace.shared.icon(for: .applicationBundle)
    let existing = ExistingLaunchers(names: [foldedName("Claude (Private)")], slugs: ["work": "Claude (Work)"])
    func sheet(name: String = "", label: String = "", color: LabelColor = .blue, error: String? = nil) -> AddInstance {
        let model = AddInstance(existing: existing, applications: "/Applications", baseIcon: base, error: error)
        model.name = name
        model.label = label
        model.color = color
        return model
    }
    let sheets: [(String, AddInstance)] = [
        ("empty", sheet()),
        ("filled", sheet(name: "Personal", color: .purple)),
        ("taken", sheet(name: "Private", color: .green)),
        ("slug-taken", sheet(name: "Work!", color: .teal)),
        ("invalid", sheet(name: "Work/Home")),
        ("failed", sheet(name: "Client", label: "ACME", color: .red,
                         error: "Could not make Claude (Client): /usr/bin/codesign exited 1: /Applications/Claude (Client).app: resource fork, Finder information, or similar detritus not allowed")),
    ]
    for (name, model) in sheets {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            write(view: AddInstanceView(model: model).background(Color(nsColor: .windowBackgroundColor)), appearance: appearance,
                  to: dir.appendingPathComponent("add-instance-\(name)-\(suffix).png"))
        }
    }

    let icons: [(label: String, color: LabelColor)] = [("WORK", .blue), ("PERSONAL", .purple), ("ACME", .red), ("家", .green)]
    let strip = VStack(alignment: .leading, spacing: 12) {
        ForEach(icons.indices, id: \.self) { i in
            HStack(alignment: .bottom, spacing: 12) {
                ForEach([128, 64, 32, 16], id: \.self) { points in
                    Image(nsImage: image(instanceIcon(base: base, label: icons[i].label, color: icons[i].color, pixels: points * 2), points: points))
                        .frame(width: CGFloat(points), height: CGFloat(points))
                }
            }
        }
    }.padding(16).background(Color(nsColor: .windowBackgroundColor))
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        write(view: strip, appearance: appearance, to: dir.appendingPathComponent("instance-icons-\(suffix).png"))
    }
    for icon in icons.prefix(3) {
        let url = dir.appendingPathComponent("instance-icon-\(icon.label.lowercased())-1024.png")
        if let png = instanceIcon(base: base, label: icon.label, color: icon.color, pixels: 1024)?.representation(using: .png, properties: [:]) {
            do { try png.write(to: url); print(url.path) } catch { print("error: could not write \(url.path): \(error)") }
        }
    }

    let bundles = dir.appendingPathComponent("launchers")
    let plan = LauncherPlan(name: "Work's \"Stuff\"", slug: "works-stuff", label: "WORK", color: .blue,
                            bundlePath: bundles.path + "/Claude (Work's \"Stuff\").app", dataDir: bundles.path + "/data/works-stuff")
    if FileManager.default.fileExists(atPath: plan.bundlePath) { print("kept \(plan.bundlePath), which already exists") }
    else {
        do { try buildLauncher(plan); print(plan.bundlePath) }
        catch { print("error: could not build \(plan.bundlePath): \((error as? LauncherError)?.description ?? "\(error)")") }
    }
}

private func image(_ rep: NSBitmapImageRep?, points: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: points, height: points))
    if let rep { image.addRepresentation(rep) }
    return image
}

@MainActor
private func write(view: some View, appearance: NSAppearance.Name, to url: URL) {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: appearance)
    hosting.setFrameSize(hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    guard let rep = retinaSnapshot(of: hosting), let png = rep.representation(using: .png, properties: [:]) else {
        print("error: could not render \(url.path)")
        return
    }
    do { try png.write(to: url); print(url.path) } catch { print("error: could not write \(url.path): \(error)") }
}

#Preview("Add Instance") {
    let model = AddInstance(existing: ExistingLaunchers(), applications: "/Applications", baseIcon: claudeIcon() ?? NSImage())
    model.name = "Personal"
    return AddInstanceView(model: model)
}
