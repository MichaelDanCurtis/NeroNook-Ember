import Combine
import AppKit
import SwiftUI
import ModuleCore
import NookPluginSDK

@MainActor final class FuegoModel: ObservableObject {
    static let pluginID = "cloud.fuego.nook-agent"
    let speech = PluginSpeechClient()
    let talk = EmberTalk()
    private var talkObservation: AnyCancellable?
    private var voiceReview: (target: UUID, server: String, company: UUID?, created: Date)?
    private var voiceTarget: (target: UUID, server: String, company: UUID?, created: Date)?
    private var conversationVoiceTicket: UUID?
    private var conversationOpening = false
    private var streamActions = false
    let workspace = PluginWorkspaceClient()
    private var workspaceObservation: AnyCancellable?
    private var conversationPreparation: (question: String, target: UUID, phase: String)?
    private var conversationReview: (id: UUID, request: NookConversationRequest)?
    private var conversationTurn: (id: UUID, request: NookConversationRequest, server: String)?
    private var conversationHandled = false
    private var conversationSubmitting = false
    private var conversationAnswer = ""
    private var conversationQuestion = ""
    private var conversationProposal: (id: String, name: String, expires: Date)?
    private var conversationStatus = "Ask Ember about your Nook."
    private var attentionLedger: HandoffAttentionLedger?
    let connection: FuegoSession?
    let handoff: HandoffController
    private lazy var waits = HandoffWaitController(controller: handoff)
    private var handoffObservation: AnyCancellable?
    private var speechObservation: AnyCancellable?
    private var catalog = PluginCatalogAccumulator()
    @Published var monitor = MonitorState()
    @Published var refreshing = false
    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    private let testing = CommandLine.arguments.contains("--protocol-test")
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var input = PluginLines()
    private var customViews = false
    private var busEnabled = false
    private var longActions = false
    private var timer: Timer?
    private var readTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let windows = PluginWindows()
    private var seenExecutions = Set<UUID>()
    init() {
        let protocolTest = CommandLine.arguments.contains("--protocol-test")
        let connection = protocolTest ? nil : FuegoSession(server: UserDefaults.standard.string(forKey: "fuegoServer") ?? "https://fuego-bridge.curtishome.org")
        self.connection = connection
        let storage = protocolTest ? FileManager.default.temporaryDirectory.appendingPathComponent("fuego-protocol-\(UUID().uuidString).json") : (try? PluginStorage.directory(id: Self.pluginID).appendingPathComponent("handoffs-v1.json")) ?? URL(fileURLWithPath: "/dev/null")
        handoff = HandoffController(api: connection ?? OfflineFuegoAPI(), store: HandoffStore(url: storage), route: .conversation)
        waits.send = { [weak self] request, update in self?.emit("bus", bus: .init(.update, requestID: request, update: update)) }
        handoffObservation = handoff.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send(); self?.publish() } }
        connection?.onReady = { [weak self] in Task { @MainActor in
            guard let self else { return }
            await self.handoff.refreshTargets()
            if !self.handoff.companies.isEmpty { UserDefaults.standard.set(true, forKey: "fuegoConnected") }
            await self.handoff.poll()
        } }
        connection?.onChange = { [weak self] in self?.stopTalk(); self?.stopConversation(); self?.handoff.invalidate() }
        if !protocolTest, let directory = try? PluginStorage.directory(id: Self.pluginID) {
            attentionLedger = HandoffAttentionLedger(url: directory.appendingPathComponent("attention-v1.json"))
        }
        workspace.didComplete = { [weak self] action, success in self?.workspaceCompleted(action, success: success) }
        workspace.send = { [weak self] in self?.emit("bus", bus: $0) }
        workspaceObservation = workspace.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send(); self?.publish() } }
        speech.send = { [weak self] in self?.emit("bus", bus: $0) }
        speech.select(UserDefaults.standard.string(forKey: "speechProvider") ?? "")
        speechObservation = speech.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send(); self?.publish() } }

        talk.client.send = { [weak self] in self?.emit("bus", bus: $0) }
        talk.client.select(UserDefaults.standard.string(forKey: "conversationProvider") ?? "")
        try? talk.chooseMode(UserDefaults.standard.string(forKey: "emberDuplex") ?? "half")
        talk.changed = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.talk.mode, forKey: "emberDuplex")
            if !self.talk.client.selectedKey.isEmpty { UserDefaults.standard.set(self.talk.client.selectedKey, forKey: "conversationProvider") }
            self.objectWillChange.send(); self.publish()
        }
        talk.question = { [weak self] words, ticket in
            guard let self, let target = self.voiceTarget, target.server == self.handoff.api.server,
                  target.company == self.handoff.company else { return }
            do { try self.askEmber(words, target: target.target, voice: ticket) }
            catch { self.talk.answer(error.localizedDescription, for: ticket) }
        }
        talk.interrupted = { [weak self] ticket in
            guard let self, self.conversationVoiceTicket == ticket else { return }
            self.stopConversation(cancelRuntime: true)
        }

        guard let url = Bundle.main.url(forResource: "NookPlugin", withExtension: "json"),
              let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
              manifest.id == Self.pluginID, (try? manifest.validate()) != nil else {
            FileHandle.standardError.write(Data("Ember packaging is invalid.\n".utf8)); exit(1)
        }
        if hosted {
            NSApplication.shared.setActivationPolicy(.accessory)
            FileHandle.standardInput.readabilityHandler = { [weak self] file in
                let data = file.availableData
                Task { @MainActor in
                    guard let self else { return }
                    guard !data.isEmpty else { self.shutdown(); exit(0) }
                    do { for message in try self.input.append(data) { self.receive(message) } }
                    catch { self.shutdown(); exit(1) }
                }
            }
        } else { refresh() }
        connection?.restore()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self else { return }; self.monitor.expire(now: StatusCodec.now); self.publish()
            if !self.testing, !self.hosted || self.session != nil { self.refresh() }
            if !self.testing { await self.handoff.poll() }
            self.workspace.tick()
            await self.waits.tick()
        } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func refresh() {
        guard !testing, readTask == nil else { return }
        generation += 1; let current = generation; refreshing = true
        readTask = Task { [weak self] in
            let result: Result<BridgeStatus, Error>
            do { result = .success(try await LocalStatusClient().read()) } catch { result = .failure(error) }
            guard let self, current == self.generation, !Task.isCancelled else { return }
            self.readTask = nil; self.refreshing = false
            switch result {
            case .success(let status): do { try self.monitor.received(status, now: StatusCodec.now) } catch { self.monitor.failed(error) }
            case .failure(let error): self.monitor.failed(error)
            }
            self.publish()
        }
    }
    func shutdown() {
        stopTalk(); stopConversation(); workspace.disconnect(); speech.stop(); generation += 1; readTask?.cancel(); readTask = nil; timer?.invalidate(); windows.closeAll(); connection?.close()
        // The independent LaunchAgent owns compute and admitted jobs.
    }
    func openWindow() {
        guard !testing else { return }
        windows.show("fuego", title: "Ember", size: .init(width: 900, height: 560)) { FuegoDashboard(model: self) }
    }
    func handle(_ event: PluginViewEvent) throws {
        guard event.panelID == "monitor" else { throw ModuleProblem("Unknown Fuego view.") }
        try definition.validate(event)
        if event.name == PluginAvatarPlayback.event {
            guard case .string(let raw)=event.values["id"],let id=UUID(uuidString:raw),case .string(let kind)=event.values["kind"] else {throw ModuleProblem("Invalid avatar reaction.")}
            if kind == "stop" {speech.stopReaction(id)}
            else if let reaction=PluginAvatarReaction(rawValue:kind), !(talk.active || conversationTurn != nil && !conversationHandled) {try speech.react(reaction,id:id)}
            publish();return
        }
        switch event.name {
        // The active handoff view has its own revision. Do not revalidate its
        // toolbar events against the older compute-only view's revision.
        case "nook":
            guard case .string(let command) = event.values["command"] else { throw ModuleProblem("Choose a Nook control.") }
            switch command {
            case "ask":
                guard case .string(let question) = event.values["text"], case .string(let rawTarget) = event.values["id"], let target = UUID(uuidString:rawTarget), !talk.active else { throw HandoffProblem.invalid }
                try askEmber(question, target: target)
            case "send_chat": try submitConversationReview()
            case "voice_prepare":
                guard streamActions, case .string(let raw) = event.values["id"], let target = UUID(uuidString:raw),
                      handoff.canSubmit, handoff.review == nil, conversationPreparation == nil,
                      conversationTurn == nil || conversationHandled, !talk.active,
                      handoff.targets.contains(where: { $0.id == target }) else { throw ModuleProblem("Connect Ember and finish the current request before Talk.") }
                voiceReview=(target,handoff.api.server,handoff.company,Date())
            case "voice_start":
                guard let consent=voiceReview, consent.server == handoff.api.server, consent.company == handoff.company,
                      Date().timeIntervalSince(consent.created) <= 120, handoff.canSubmit, handoff.review == nil,
                      handoff.targets.contains(where: { $0.id == consent.target }) else { voiceReview=nil; throw ModuleProblem("Review this Talk session again.") }
                voiceReview=nil; voiceTarget=consent; speech.stop()
                do { try talk.start() } catch { voiceTarget=nil; throw error }
            case "voice_back": voiceReview=nil
            case "voice_stop": stopTalk(cancelRuntime:true)
            case "voice_mode":
                guard case .string(let mode)=event.values["text"] else { throw HandoffProblem.invalid }
                try talk.chooseMode(mode)
            case "voice_provider":
                guard case .string(let key)=event.values["text"] else { throw HandoffProblem.invalid }
                stopTalk(); talk.client.select(key); UserDefaults.standard.set(key,forKey:"conversationProvider")
            case "voice_sensitivity":
                guard case .string(let raw)=event.values["text"],let value=Int(raw) else { throw ModuleProblem("Choose a sensitivity from 0 to 100.") };try talk.client.setInterruptionSensitivity(value)
            case "voice_expression":try talk.chooseExpression(NookConversationViewControl.expression(event.values))
            case "voice_settings": stopTalk(); try talk.client.openSettings(mode:talk.mode)
            case "stop_chat": if talk.active { stopTalk(cancelRuntime:true) } else { stopConversation(cancelRuntime:true) }
            case "open_chat":
                guard let proposal=conversationProposal, proposal.expires > Date() else { conversationProposal=nil; throw ModuleProblem("This opening proposal expired. Ask Ember again.") }
                conversationProposal=nil; conversationStatus="Review opening " + proposal.name + " in the Nook."
                do { conversationOpening=true; try workspace.open(proposal.id) } catch { conversationOpening=false; conversationStatus=error.localizedDescription; throw error }
            case "read_chat":
                guard !conversationAnswer.isEmpty else { throw ModuleProblem("No Ember answer to read yet.") }
                try speech.read(conversationAnswer)
            case "modules": try workspace.refreshModules()
            case "watch": try workspace.watch()
            case "unwatch": workspace.stopWatching()
            case "cancel": workspace.stop()
            case "seen": attentionLedger?.acknowledge(); publish()
            case "open":
                guard case .string(let id) = event.values["id"] else { throw ModuleProblem("Choose a module.") }
                try workspace.open(id)
            default: throw ModuleProblem("Unknown Nook control.")
            }; publish(); return
        case "refresh": refresh(); return
        case "open_window": openWindow(); return
        case "connect_fuego": connection?.connect(); return
        case "refresh_jobs": Task { await handoff.refreshTargets(); await handoff.poll() }; return
        case "company":
            if case .string(let value) = event.values["id"], let id = UUID(uuidString: value), handoff.companies.contains(where: { $0.id == id }) {
                stopTalk(); stopConversation(); handoff.dismissReview(); handoff.company = id; Task { await handoff.refreshTargets() }
            }; return
        case "review_task":
            guard case .string(let value) = event.values["target"], let id = UUID(uuidString: value), case .string(let task) = event.values["task"] else { throw HandoffProblem.invalid }
            try handoff.prepare(target: id, task: task); return
        case "send_task":
            guard case .string(let value) = event.values["id"], let id = UUID(uuidString: value) else { throw HandoffProblem.invalid }
            Task { await handoff.approve(id) }; return
        case "dismiss_review": handoff.dismissReview(); return
        case "select_job":
            if case .string(let value) = event.values["id"], let id = UUID(uuidString: value), handoff.jobs.contains(where: { $0.id == id }) { handoff.selectedJob = id }; return
        case "cancel_job":
            guard case .string(let value) = event.values["id"], let id = UUID(uuidString: value) else { throw HandoffProblem.invalid }
            Task { await handoff.cancel(id) }; return
        case "recheck_job":
            guard case .string(let value) = event.values["id"], let id = UUID(uuidString: value) else { throw HandoffProblem.invalid }
            Task { await handoff.reconcile(id); await handoff.poll() }; return
        case "open_job":
            guard case .string(let value) = event.values["id"], let id = UUID(uuidString: value), let url = handoff.inspectURL(id) else { return }
            NSWorkspace.shared.open(url); return
        default: break
        }
        if event.name == "speech_provider", case .string(let key) = event.values["key"] { speech.select(key); UserDefaults.standard.set(key, forKey: "speechProvider"); return }
        if event.name == "stop_speech" { speech.stop(); return }
        if event.name == "read_status" {
            monitor.expire(now: StatusCodec.now)
            let text = monitor.status.map { "Fuego. \(monitor.title). \($0.activeJobs) active jobs and \($0.uncertainJobs) uncertain jobs. \(monitor.detail)" } ?? "Fuego status is unavailable. \(monitor.detail)"
            try speech.read(text); return
        }
        throw ModuleProblem("Unknown Fuego event.")
    }
    private func receive(_ message: PluginMessage) {
        guard message.pluginID == Self.pluginID else { shutdown(); exit(1) }
        if session == nil {
            guard message.type == "hello" else { shutdown(); exit(1) }
            session = message.session; PluginAppearanceStore.shared.beginSession(pluginID:Self.pluginID,session:message.session)
            customViews = message.features?.contains("custom-views-v1") == true
            busEnabled = message.features?.contains("actions-v1") == true
            workspace.accessRequestsAvailable = busEnabled && message.features?.contains("action-access-v1") == true
            longActions = busEnabled && message.features?.contains("actions-long-running-v1") == true
            streamActions = longActions && message.features?.contains("action-stream-v1") == true
            talk.client.accessRequestsAvailable = streamActions && workspace.accessRequestsAvailable
            emit("ready", features: ["appearance-v1", "dashboard-v1", "panels-v1"] + (customViews ? ["custom-views-v1"] : []) + (busEnabled ? ["actions-v1"] : []) + (longActions ? ["actions-long-running-v1"] : []) + (workspace.accessRequestsAvailable ? ["action-access-v1"] : []) + (streamActions ? ["action-stream-v1"] : []))
            if busEnabled { emit("bus", bus: .init(.register, registration: .init(actions: [MonitorState.readAction, Self.jobReadAction, HandoffActions.list, HandoffActions.prepare, HandoffActions.read] + (longActions ? [HandoffActions.wait] : []), channels: [.init("status", title: "Fuego compute status", kind: .state, schema: MonitorState.schema), .init("job_status", title: "Selected Fuego handoff", kind: .state, schema: Self.jobSchema)]))) }
            if busEnabled { emit("bus", bus: .init(.discover)) }
            publish(); refresh(); return
        }
        guard message.session == session else { shutdown(); exit(1) }; if message.type == "appearance" { _ = PluginAppearanceStore.shared.receive(message); return }
        if message.type == "action", let action = message.action {
            if action == "refresh" { refresh() }
            if action == "open_window" || action == "configure" { openWindow() }
        }
        if message.type == "viewEvent", customViews, let event = message.viewEvent { try? handle(event) }
        if let bus = message.bus, busEnabled {
            speech.receive(bus); workspace.receive(bus); if streamActions { talk.client.receive(bus) }
            if bus.operation == .cancel { waits.requestCancel(bus.requestID); Task { await waits.tick() } }
            if bus.operation == .catalog, (try? catalog.receive(bus)) == true { speech.catalog(catalog.entries); workspace.catalog(catalog.entries); if streamActions { talk.client.catalog(catalog.entries) } }
        }
        if message.type == "bus", busEnabled, let bus = message.bus, bus.operation == .execute {
            guard seenExecutions.count < 4096, seenExecutions.insert(bus.requestID).inserted else { return }
            monitor.expire(now: StatusCodec.now)
            if bus.address == .init(Self.pluginID, "wait_for_handoff"), longActions {
                do { try waits.start(bus.requestID, values: bus.values ?? [:]); Task { await waits.tick() } }
                catch { emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.failed, message: "The original Fuego draft/job is unavailable or already being watched. Nothing was sent."))) }
                return
            }
            if bus.address == .init(Self.pluginID, "list_handoff_targets"), (bus.values ?? [:]).isEmpty {
                emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Available targets from this plugin's connection. Each draft is rechecked before Send.", values: HandoffActions.targetValues(handoff.targets)))); return
            }
            if bus.address == .init(Self.pluginID, "prepare_handoff") {
                do {
                    let values = try HandoffActions.prepareDraft(bus.values ?? [:], controller: handoff)
                    openWindow()
                    emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Draft prepared; waiting for your own Fuego review. No job started.", values: values)))
                } catch { emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.failed, message: error.localizedDescription))) }
                return
            }
            if bus.address == .init(Self.pluginID, "read_handoff_status") {
                do {
                    let values = bus.values ?? [:]; try HandoffActions.read.input.validate(values)
                    guard case .string(let raw) = values["request_id"], let id = UUID(uuidString: raw) else { throw HandoffProblem.invalid }
                    let job = handoff.jobs.first { $0.id == id && $0.server == handoff.api.server }
                    let review = handoff.review.flatMap { $0.id == id && $0.server == handoff.api.server ? $0 : nil }
                    emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Original handoff metadata; observed_at identifies its last confirmed read.", values: HandoffActions.statusValues(job, review: review))))
                } catch { emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.failed, message: error.localizedDescription))) }
                return
            }
            if bus.address == .init(Self.pluginID, "read_job_status"), (bus.values ?? [:]).isEmpty {
                emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Selected handoff metadata", values: jobValues))); return
            }
            let valid = bus.address == .init(Self.pluginID, "read_status") && (bus.values ?? [:]).isEmpty
            emit("bus", bus: .init(.update, requestID: bus.requestID, update: .init(valid ? .succeeded : .failed, message: valid ? "Local compute metadata" : "Invalid read request", values: valid ? monitor.values : [:])))
        }
    }
    var definition: PluginCustomView {
        var view = monitor.customView
        view.avatarReactions=true;view.avatarPlayback=speech.avatarPlayback
        view.state["reactionSpeaking"] = .boolean(speech.avatarPlayback != nil)
        let choices = speech.providers.map { ["key": $0.address.key, "name": $0.action?.title ?? $0.address.plugin] }
        view.state["speechProviders"] = .string(String(data: (try? JSONEncoder().encode(choices)) ?? Data(), encoding: .utf8) ?? "[]")
        view.state["speechProvider"] = .string(speech.selectedKey)
        view.state["speechActive"] = .boolean(speech.active)
        let validSpeech = speech.providers.contains { $0.address.key == speech.selectedKey }
        view.state["speechStatus"] = .string(validSpeech && speech.status == "Choose an allowed speech provider." ? "" : String(speech.status.prefix(240)))
        view.events += [.init("read_status"), .init("stop_speech"), .init("speech_provider", input: .init([.init("key", .string)]))]
        view.revision = "ember_voice1"
        view.state["voiceAvailable"] = .boolean(streamActions)
        view.state["voiceActive"] = .boolean(talk.active)
        view.state["voicePhase"] = .string(talk.phase)
        view.state["voiceStatus"] = .string(String(talk.displayStatus.prefix(240)))
        view.state["voicePartial"] = .string(String(talk.partial.prefix(600)))
        view.state["voiceControls"] = .string((try? talk.client.controls?.encoded()) ?? "")
        view.state["voiceReady"] = .boolean(talk.client.ready)
        view.state["voiceMode"] = .string(talk.mode)
        view.state["voiceExpressionEnabled"] = .boolean(talk.expressionEnabled)
        view.state["voiceLevel"] = .number(talk.level)
        view.state["voiceOutputLevel"] = .number(talk.outputLevel)
        view.state["voiceExpression"] = .string(String(decoding:(try? JSONEncoder().encode(talk.expression.pose)) ?? Data(),as:UTF8.self))
        view.state["voiceReview"] = .boolean(voiceReview != nil)
        view.state["voiceTarget"] = .string(handoff.targets.first(where: { $0.id == (voiceReview?.target ?? voiceTarget?.target) })?.name ?? "")
        view.state["voiceProviders"] = .string(String(data:(try? JSONEncoder().encode(talk.client.providers.map { ["id":$0.address.key,"name":$0.address.plugin] })) ?? Data(),encoding:.utf8) ?? "[]")
        view.state["voiceProvider"] = .string(talk.client.selectedKey)
        func json(_ value: Any) -> PluginValue { .string(String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), encoding: .utf8) ?? "[]") }
        view.state["nookModules"] = json(workspace.modules)
        view.state["nookAttention"] = json(workspace.attention)
        view.state["nookStatus"] = .string(workspace.status)
        view.state["nookBusy"] = .boolean(workspace.busy)
        view.state["nookWatching"] = .boolean(workspace.watching)
        view.state["ownAttention"] = .boolean(attentionLedger?.attention != nil)
        view.events += [NookConversationViewControl.definition]
        view.state["chatQuestion"] = .string(conversationQuestion)
        view.state["chatAnswer"] = .string(conversationAnswer)
        view.state["chatStatus"] = .string(conversationStatus)
        view.state["chatPreparing"] = .boolean(conversationPreparation != nil)
        view.state["chatBusy"] = .boolean(conversationPreparation != nil || conversationReview != nil || (conversationTurn != nil && !conversationHandled))
        view.state["chatReview"] = .string(conversationReview?.request.context ?? "")
        view.state["chatModule"] = .string(conversationProposal?.name ?? "")
        view.state["server"] = .string(handoff.api.server)
        view.state["handoffMessage"] = .string(handoff.message)
        view.state["handoffBusy"] = .boolean(handoff.busy)
        view.state["canSubmit"] = .boolean(handoff.canSubmit)
        view.state["unconfirmedSave"] = .boolean(handoff.hasUnconfirmedSave)
        view.state["companies"] = json(handoff.companies.map { ["id": $0.id.uuidString, "name": $0.name] })
        view.state["company"] = .string(handoff.company?.uuidString ?? "")
        view.state["targets"] = json(handoff.targets.prefix(12).map { ["id": $0.id.uuidString, "name": $0.name, "provider": $0.provider, "workspace": $0.workspace, "device": $0.device.uuidString] })
        view.state["handoffs"] = json(handoff.jobs.map { ["id": $0.id.uuidString, "title": String($0.task.prefix(90)), "phase": $0.phase.title] })
        view.state["selectedJob"] = .string(handoff.activeJob?.id.uuidString ?? "")
        if let review = handoff.review {
            view.state["reviewTask"] = .string(review.task)
            view.state["reviewInstructions"] = .string(review.target.instructions)
            view.state["review"] = json(["id": review.id.uuidString, "agent": review.target.name, "organization": review.target.companyName, "device": review.target.device.uuidString, "workspace": review.target.workspace, "provider": review.target.provider, "account": review.target.account, "server": review.server])
        } else { view.state["review"] = .string("null") }
        if let job = handoff.activeJob {
            view.state["job"] = json(["id": job.id.uuidString, "task": job.task, "phase": job.phase.title, "state": job.phase.rawValue, "detail": job.detail, "result": job.result, "events": job.events, "agent": job.target.name, "workspace": job.target.workspace, "run": job.run?.uuidString ?? "", "issue": job.issueLabel ?? job.issue?.uuidString ?? "", "lastRead": job.lastRead?.timeIntervalSince1970 ?? 0, "admitted": job.admitted, "canCancel": job.run != nil && !job.phase.settled && !job.cancelSent && job.server == handoff.api.server, "canRecheck": job.phase == .uncertain && job.server == handoff.api.server, "canOpen": job.issue != nil, "created": job.created.timeIntervalSince1970])
        } else { view.state["job"] = .string("null") }
        let id = PluginValueSchema([.init("id", .string)])
        view.events += [.init("connect_fuego"), .init("refresh_jobs"), .init("company", input: id), .init("review_task", input: .init([.init("target", .string), .init("task", .string)])), .init("send_task", input: id), .init("dismiss_review"), .init("select_job", input: id), .init("cancel_job", input: id), .init("open_job", input: id), .init("recheck_job", input: id)]
        // Keep full reviewed text. A large prior result or catalog cannot make
        // a review exceed the shared SDK's 32 KiB view-state budget.
        if (try? JSONEncoder().encode(view.state).count) ?? Int.max > 32768 {
            view.state["job"] = .string("null")
            view.state["handoffs"] = .string("[]")
            view.state["jobs"] = .string("[]")
            view.state["targets"] = .string("[]")
            view.state["nookModules"] = .string("[]")
            view.state["nookAttention"] = .string("[]")
        }
        return view
    }
    static var jobSchema: PluginValueSchema { .init([.init("available", .boolean), .init("phase", .string), .init("run_id", .string), .init("task_id", .string), .init("admitted", .boolean), .init("observed_at", .number, minimum: 0)]) }
    static var jobReadAction: PluginRegisteredAction { .init("read_job_status", title: "Read selected Fuego handoff status", output: jobSchema, effect: .readOnly, timeoutSeconds: 5) }
    var jobValues: [String: PluginValue] {
        let job = handoff.activeJob
        return ["available": .boolean(job != nil), "phase": .string(job?.phase.title ?? "No handoff"), "run_id": .string(job?.run?.uuidString ?? ""), "task_id": .string(job?.issue?.uuidString ?? ""), "admitted": .boolean(job?.admitted ?? false), "observed_at": .number((job?.lastRead?.timeIntervalSince1970 ?? 0) * 1000)]
    }
    private func publish() {
        synchronizeConversation()
        monitor.expire(now: StatusCodec.now)
        attentionLedger?.observe(handoff.jobs)
        var snapshot = monitor.snapshot(customViews: customViews)
        if customViews { snapshot.panels = [.init("monitor", "Jobs", customView: definition)] }
        snapshot.status = handoff.activeJob?.detail ?? handoff.message
        snapshot.assistantSpeech = .init(speaking:talk.phase == "speaking",level:talk.outputLevel,expression:talk.expression.pose)
        snapshot.attention = attentionLedger?.attention
        if let review=handoff.review {
            snapshot.attention = .init(id:review.id.uuidString,kind:.needsYou,title:"Ember has a task for review")
        }

        if let job = handoff.activeJob { snapshot.activity = "Fuego · \(job.phase.title)"; snapshot.badge = job.phase.title }
        else { snapshot.activity = "Fuego · \(handoff.targets.isEmpty ? "Connect account" : "Ready for a task")"; snapshot.badge = handoff.targets.isEmpty ? "Sign in" : "Ready" }
        do { try snapshot.validate() }
        catch { FileHandle.standardError.write(Data("Fuego display validation failed: \(error.localizedDescription)\n".utf8)); shutdown(); exit(1) }
        emit("snapshot", snapshot: snapshot)
        if busEnabled { emit("bus", bus: .init(.publish, address: .init(Self.pluginID, "status"), values: monitor.values, lifetime: 4)) }
        if busEnabled { emit("bus", bus: .init(.publish, address: .init(Self.pluginID, "job_status"), values: jobValues, lifetime: 4)) }
    }
    private func askEmber(_ question: String, target: UUID, voice: UUID? = nil) throws {
        guard conversationPreparation == nil, conversationReview == nil, conversationTurn == nil || conversationHandled,
              !workspace.busy, handoff.review == nil, handoff.targets.contains(where: { $0.id == target }) else { throw ModuleProblem("Finish the current request before asking Ember.") }
        guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, question.utf8.count <= 600, HandoffTarget.printable(question) else { throw HandoffProblem.invalid }
        conversationVoiceTicket=voice
        conversationPreparation=(question,target,"read_modules"); conversationProposal=nil
        conversationQuestion=question; conversationAnswer=""; conversationStatus="Reading current Nook context…"
        do { try workspace.refreshModules() } catch { conversationPreparation=nil; throw error }
    }
    private func submitConversationReview() throws {
        guard let review=conversationReview, handoff.review?.id == review.id,
              Date().timeIntervalSince(review.request.created) <= 30 else {
            handoff.dismissReview(); conversationReview=nil; throw ModuleProblem("Nook context expired. Ask again to refresh it.")
        }
        conversationTurn=(review.id,review.request,handoff.api.server); conversationHandled=false; conversationSubmitting=true; conversationReview=nil
        conversationStatus="Ember is thinking…"
        Task {
            guard self.conversationTurn?.id == review.id else { return }
            await handoff.approve(review.id); self.conversationSubmitting=false; self.publish()
        }
    }
    private func answerVoice(_ text: String, cue: PluginExpressionCue? = nil) {
        if let ticket=conversationVoiceTicket { talk.answer(text,for:ticket,cue:cue) }
    }
    private func stopTalk(cancelRuntime: Bool = false) {
        voiceReview=nil; voiceTarget=nil
        if cancelRuntime { stopConversation(cancelRuntime:true) }
        else if conversationVoiceTicket != nil { stopConversation() }
        talk.stop()
    }
    private func workspaceCompleted(_ action: String, success: Bool) {
        guard let prep=conversationPreparation else {
            if action == "open_module" { conversationOpening=false; conversationStatus = success ? "Module opened in the Nook." : "Opening ended. No request was retried." }
            return
        }
        guard action == prep.phase else { return }
        guard success else { conversationPreparation=nil; conversationStatus="Nook context could not be read. Nothing was sent."; answerVoice(conversationStatus); return }
        do {
            if action == "read_modules" {
                conversationPreparation=(prep.question,prep.target,"read_attention")
                try workspace.refreshAttention()
            } else {
                conversationPreparation=nil
                let request=try NookConversationRequest(question:prep.question,modules:workspace.modules,attention:workspace.attention)
                try handoff.prepare(target:prep.target,task:request.prompt)
                guard let review=handoff.review else { throw HandoffProblem.invalid }
                conversationReview=(review.id,request)
                conversationStatus="Review the Nook context before sending."
                if let ticket=conversationVoiceTicket, talk.active, talk.ticket == ticket,
                   let consent=voiceTarget, consent.target == prep.target, consent.server == handoff.api.server,
                   consent.company == handoff.company { try submitConversationReview() }
            }
        } catch { conversationPreparation=nil; conversationStatus=error.localizedDescription; answerVoice(conversationStatus) }
    }
    private func stopConversation(cancelRuntime: Bool = false) {
        let reading=conversationPreparation != nil
        conversationPreparation=nil; conversationProposal=nil; conversationHandled=true
        if let review=conversationReview, handoff.review?.id == review.id { handoff.dismissReview() }
        conversationReview=nil
        if reading || conversationOpening { conversationOpening=false; workspace.stop() }
        conversationStatus = "Local conversation closed. Saved Fuego jobs are unchanged."
        if cancelRuntime {
            let job=conversationTurn.flatMap { turn in handoff.jobs.first { $0.id == turn.id } }
            let outcome=NookConversationStop(job:job,submitting:conversationSubmitting)
            conversationStatus=outcome.message
            if case .admitted(let id)=outcome { Task { await handoff.cancel(id) } }
        }
        conversationTurn=nil; conversationVoiceTicket=nil
    }
    private func synchronizeConversation() {
        if let proposal=conversationProposal, proposal.expires <= Date() { conversationProposal=nil; conversationStatus="Opening proposal expired. Ask Ember again." }
        guard let turn=conversationTurn, !conversationHandled else { return }
        guard turn.server == handoff.api.server else { conversationHandled=true; conversationProposal=nil; answerVoice("The Fuego connection changed. Please start Talk again."); return }
        guard let job=handoff.jobs.first(where: { $0.id == turn.id }) else {
            if !conversationSubmitting && !handoff.busy { conversationHandled=true; conversationStatus=handoff.message; answerVoice(conversationStatus) }
            return
        }
        guard job.phase.settled else { conversationStatus=job.phase.title; return }
        conversationHandled=true
        guard job.phase == .succeeded, !job.cancelSent, job.run != nil, job.task == turn.request.prompt else {
            conversationStatus=job.detail; answerVoice(conversationStatus); return
        }
        do {
            let response=try turn.request.response(job.result)
            conversationAnswer=response.answer
            if let id=response.moduleID, let name=response.moduleName {
                conversationProposal=(id,name,Date().addingTimeInterval(60)); conversationStatus="Ember has an opening proposal."
            } else { conversationStatus="Ember replied using the reviewed Nook snapshot." }
            if let ticket=conversationVoiceTicket, talk.active, talk.ticket == ticket {
                if let proposal=conversationProposal {
                    conversationProposal=nil
                    do {
                        conversationOpening=true
                        try workspace.open(proposal.id)
                        answerVoice(response.answer + " Review opening " + proposal.name + " in the Nook.")
                    } catch { conversationOpening=false; answerVoice(response.answer + " " + error.localizedDescription) }
                } else { answerVoice(response.answer,cue:response.cue) }
            }
        } catch { conversationStatus=error.localizedDescription; answerVoice(conversationStatus) }
    }
    private func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil, bus: PluginBusMessage? = nil) {
        guard let session else { return }
        if type != "ready" { sequence += 1 }
        do { try FileHandle.standardOutput.write(contentsOf: PluginMessage(type: type, pluginID: Self.pluginID, session: session, sequence: sequence, snapshot: snapshot, features: features, bus: bus).encoded()) }
        catch { shutdown(); exit(0) }
    }
}
struct FuegoDashboard: View {
    @ObservedObject var model: FuegoModel
    var body: some View {
        VStack(spacing: 0) {
            if let root = Bundle.main.resourceURL?.appendingPathComponent("Views") {
                PluginWebSurface(root: root, panelID: "monitor", definition: model.definition) { try model.handle($0) }
            } else { Text("Package Ember to load its local view.").padding(30) }
        }.frame(minWidth: 620, minHeight: 350)
    }
}
@main struct FuegoAgentApp: App {
    @StateObject private var model: FuegoModel
    init() {
        if CommandLine.arguments.contains("--check-compute") {
            do {
                let status = try LocalStatusClient().readBlocking()
                var data = try JSONEncoder().encode(status); data.append(10)
                FileHandle.standardOutput.write(data); exit(0)
            } catch {
                FileHandle.standardError.write(Data(((error as? BrokerProblem)?.localizedDescription ?? "Fuego Compute status unavailable.").utf8)); exit(1)
            }
        }
        _model = StateObject(wrappedValue: FuegoModel())
    }
    var body: some Scene {
        WindowGroup(model.hosted ? "Ember Launcher" : "Ember") { FuegoDashboard(model: model).pluginThemed().onAppear {
            if model.hosted { NSApp.windows.first(where: { $0.title == "Ember Launcher" })?.orderOut(nil) }
        } }
    }
}
@MainActor private final class OfflineFuegoAPI: FuegoAPI {
    let server = "https://fuego-bridge.curtishome.org"
    func request(_ request: FuegoRequest) async throws -> Data { throw HandoffProblem.signIn }
}
