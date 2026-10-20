import AppKit
import SwiftUI
import ModuleCore
import NookPluginSDK

@MainActor final class ModuleModel: ObservableObject {
    @Published var state = DemoState()
    @Published var settingsVisible = false
    @Published var title = "Module"
    private var pluginID = ""
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var cards = false
    private var busEnabled = false
    private var forms = false
    private var customViews = false
    @Published var studioMode = "Focus"
    @Published var studioTitle = "My workspace"
    private let windows = PluginWindows()
    private var input = PluginLines()
    private var timer: Timer?
    private var replay: [DemoState] = []
    private var replayIndex = 0
    private var activity: NSObjectProtocol?
    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    var testing: Bool { CommandLine.arguments.contains("--protocol-test") }
    init() {
        do {
            guard let url = Bundle.main.url(forResource: "NookPlugin", withExtension: "json") else { throw ModuleProblem("Package the app before opening it.") }
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
            try manifest.validate(); pluginID = manifest.id; title = manifest.name
            if let index = CommandLine.arguments.firstIndex(of: "--replay"), CommandLine.arguments.indices.contains(index + 1) {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                guard bytes.count <= 32768 else { throw ModuleProblem("Replay is too large.") }
                replay = try JSONDecoder().decode([DemoState].self, from: bytes)
                guard (1...30).contains(replay.count) else { throw ModuleProblem("Use 1–30 replay states.") }
                try replay.forEach { try $0.validate() }; state = replay[0]
            }
        } catch { FileHandle.standardError.write(Data("Module startup failed. Check packaging and replay data.\n".utf8)); exit(1) }
        if hosted {
            NSApplication.shared.setActivationPolicy(.accessory)
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Serve the enabled Nook module")
            FileHandle.standardInput.readabilityHandler = { [weak self] file in
                let data = file.availableData
                Task { @MainActor in
                    guard let self else { return }
                    guard !data.isEmpty else { exit(0) }
                    do { for message in try self.input.append(data) { self.receive(message) } }
                    catch { exit(1) }
                }
            }
        }
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            if !self.replay.isEmpty { self.replayIndex = min(self.replayIndex + 1, self.replay.count - 1); self.state = self.replay[self.replayIndex] }
            self.publish()
        } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func perform(_ id: String) {
        guard state.snapshot(title: title, cards: cards).enabledDisplayAction(id) != nil else { return }
        state.apply(id); publish()
    }
    func showSettings() {
        settingsVisible = true
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
    private func receive(_ message: PluginMessage) {
        guard message.pluginID == pluginID else { exit(1) }
        if session == nil {
            guard message.type == "hello" else { exit(1) }
            session = message.session
            customViews = message.features?.contains("custom-views-v1") == true
            forms = message.features?.contains("forms-v1") == true
            cards = message.features?.contains("control-cards-v1") == true
            busEnabled = message.features?.contains("actions-v1") == true
            emit("ready", features: ["dashboard-v1", "panels-v1", "control-cards-v1", "actions-v1", "forms-v1", "custom-views-v1"])
            if busEnabled {
                emit("bus", bus: .init(.register, registration: .init(actions: [
                    DemoState.editAction,
                    .init("read_status", title: "Read demo status", output: .init([.init("available", .boolean), .init("count", .number)]))
                ], channels: [.init("status", title: "Demo status", kind: .state, schema: .init([.init("available", .boolean), .init("count", .number)]))])))
            }
            publish(); return
        }
        guard message.session == session else { exit(1) }
        if message.type == "viewEvent", let event = message.viewEvent, customViews { try? handleViewEvent(event) }
        if message.type == "action", let action = message.action {
            if action == "configure" { showSettings() }
            else if action == "reset" && !cards {
                // Older hosts cannot render in-card confirmation. Keep review in
                // the plugin window, then recheck the exact state before applying.
                let expected = state
                guard state.snapshot(title: title, cards: false).enabledDisplayAction(action) != nil else { return }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(); alert.messageText = "Reset demo counter?"
                alert.informativeText = "Only this module’s demo counter will change."
                alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn, state == expected { perform(action) }
            } else { perform(action) }
        }
        if message.type == "bus", let bus = message.bus, bus.operation == .execute {
            if busEnabled, bus.address?.plugin == pluginID, bus.address?.name == "edit_demo" {
                do { try state.applyEdit(bus.values ?? [:]); publish(); emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Demo updated"))) }
                catch { emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.failed, message: error.localizedDescription))) }
                return
            }
            let valid = busEnabled && bus.address?.plugin == pluginID && bus.address?.name == "read_status" && (bus.values ?? [:]).isEmpty
            emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(valid ? .succeeded : .failed, values: valid ? values : [:])))
        }
    }
    var customDefinition: PluginCustomView {
        .init(entry: "studio/index.html", revision: "studio1", state: ["mode": .string(studioMode), "title": .string(studioTitle)], events: [
            .init("set_mode", input: .init([.init("mode", .string)])),
            .init("rename", input: .init([.init("title", .string)])), .init("open_window")
        ])
    }
    func handleViewEvent(_ event: PluginViewEvent) throws {
        guard event.panelID == "studio" else { throw ModuleProblem("Unknown view.") }
        try customDefinition.validate(event)
        switch event.name {
        case "set_mode":
            guard case .string(let mode) = event.values["mode"], ["Focus", "Review"].contains(mode) else { throw ModuleProblem("Unknown mode.") }
            studioMode = mode
        case "rename":
            guard case .string(let title) = event.values["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModuleProblem("Enter a title.") }
            studioTitle = String(title.prefix(60))
        case "open_window": if !testing { showCustomWindow() }
        default: throw ModuleProblem("Unknown event.")
        }
        publish()
    }
    func showCustomWindow() { windows.show("studio", title: "Plugin-owned native window") { NativeStudioWindow(model: self) } }
    private var values: [String: PluginValue] { ["available": .boolean(state.available), "count": .number(Double(state.count))] }
    private func publish() {
        var snapshot = state.snapshot(title: title, cards: cards)
        if customViews { snapshot.panels?.append(.init("studio", "Custom view", customView: customDefinition)) }
        if forms { snapshot.panels?.append(.init("edit", "Edit", forms: [state.editForm])) }
        guard (try? snapshot.validate()) != nil else { exit(1) }
        emit("snapshot", snapshot: snapshot)
        if busEnabled { emit("bus", bus: .init(.publish, address: .init(pluginID, "status"), values: values, lifetime: 8)) }
    }
    private func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil, bus: PluginBusMessage? = nil) {
        guard let session else { return }
        if type != "ready" { sequence += 1 }
        do { try FileHandle.standardOutput.write(contentsOf: PluginMessage(type: type, pluginID: pluginID, session: session, sequence: sequence, snapshot: snapshot, features: features, bus: bus).encoded()) }
        catch { exit(0) }
    }
}

struct DashboardView: View {
    @ObservedObject var model: ModuleModel
    @State private var reviewReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.mint); Text(model.title).font(.headline); Spacer(); Text("LOCAL PREVIEW").font(.caption).foregroundStyle(.secondary); Button { model.showSettings() } label: { Image(systemName: "gearshape") }.help("Module settings") }
            VStack(alignment: .leading, spacing: 20) {
                Text("Your first module").font(.title2.bold())
                Button("Open custom native window") { model.showCustomWindow() }
                Text(String(model.state.count)).font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                Text("One shared surface. Your module owns its behavior.").foregroundStyle(.secondary)
                HStack { Button("Add one") { model.perform("increment") }.buttonStyle(.borderedProminent).disabled(!model.state.available || model.state.count >= 999); Button("Reset") { reviewReset = true }.disabled(!model.state.available || model.state.count == 0) }
                Spacer(minLength: 0)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        }.padding(20).frame(width: 720, height: 405).background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .safeAreaInset(edge: .bottom) { Text(model.state.message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
        .frame(width: 720).fixedSize()
        .preferredColorScheme(.dark).tint(.mint)
        .alert("Reset demo counter?", isPresented: $reviewReset) { Button("Cancel", role: .cancel) {}; Button("Reset") { model.perform("reset") } } message: { Text("Only this module’s demo counter will change.") }
        .sheet(isPresented: $model.settingsVisible) {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Module settings").font(.title2.bold()); Spacer(); Button("Done") { model.settingsVisible = false } }
                Toggle("Demo available", isOn: $model.state.available)
                Text("This starter has no device, account or network access. Put real integration setup here, behind the gear button.").foregroundStyle(.secondary)
            }.padding(24).frame(width: 430)
        }
        .onAppear { if model.hosted { NSApp.windows.first(where: { $0.canBecomeKey })?.orderOut(nil) } }
    }
}
struct NativeStudioWindow: View {
    @ObservedObject var model: ModuleModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("PLUGIN-OWNED WINDOW", systemImage: "macwindow").font(.caption.bold()).foregroundStyle(.mint)
            Text(model.studioTitle).font(.largeTitle.bold())
            Text("This is arbitrary SwiftUI in the plugin process. The host does not own this window or its layout.").foregroundStyle(.secondary)
            Picker("Mode", selection: $model.studioMode) { Text("Focus").tag("Focus"); Text("Review").tag("Review") }.pickerStyle(.segmented)
            Spacer()
            Text("The custom Nook view receives these changes through the SDK.").font(.caption)
        }.padding(30).frame(minWidth: 420, minHeight: 240).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.06, green: 0.07, blue: 0.11)).preferredColorScheme(.dark)
    }
}
@main struct StarterApp: App {
    @StateObject private var model: ModuleModel
    init() { let instance = ModuleModel(); _model = StateObject(wrappedValue: instance) }
    var body: some Scene { WindowGroup { DashboardView(model: model) }.windowResizability(.contentSize) }
}
