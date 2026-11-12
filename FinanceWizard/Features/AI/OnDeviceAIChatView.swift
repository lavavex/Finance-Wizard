//
//  OnDeviceAIChatView.swift
//  Finance Wizard
//
//  Ask chat: a model menu, streaming, and a persisted thread. AskConversation runs the on-device
//  model and AskCloudChat runs Claude and Grok.
//

import GameController
import SwiftData
import SwiftUI

private struct AskBubble: Identifiable {
    let id: UUID
    let isUser: Bool
    var text: String
    var warning: String?
    var modelName: String?
    var seconds: Double?
    var remembered: [String] = []
    /// Failures show in the chat but aren't sent back to a model.
    var failed = false
}

/// What to do once a provider has a key and consent.
private struct AskSetupRequest: Identifiable {
    let model: AskModel
    let tryingQuestion: Bool
    var id: String { model.id }
}

struct OnDeviceAIChatView: View {
    /// Asked as soon as the chat opens, for follow-ups from elsewhere in the app.
    var initialQuestion: String?

    @Environment(\.modelContext) private var financeContext

    @State private var draft = ""
    @State private var messages: [AskBubble] = []
    @FocusState private var composerFocused: Bool
    @State private var followUps: [String] = []
    @State private var promptIndex = 0
    @State private var conversation: AskConversation?
    @State private var isSending = false
    @State private var thread: AskThread?
    @State private var askContext = ModelContext(AskStore.container)
    @State private var selectedModel = AskModel.selected
    @State private var setupRequest: AskSetupRequest?
    @State private var confirmClear = false

    private let promptHints = [
        "What's my biggest category?",
        "How much did I spend this month?",
        "What recurring charges are coming up?",
    ]

    var body: some View {
        NavigationStack {
            chatBody
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { modelMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear chat", systemImage: "trash") { confirmClear = true }
                            .disabled(messages.isEmpty || isSending)
                            .confirmationDialog("Clear this chat?", isPresented: $confirmClear) {
                                Button("Clear Chat", role: .destructive) { clearChat() }
                            }
                    }
                }
        }
        .sheet(item: $setupRequest) { request in
            NavigationStack {
                if let provider = request.model.provider {
                    AskProviderSetupView(provider: provider) {
                        finishSetup(request)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { setupRequest = nil }
                        }
                    }
                }
            }
        }
        .task {
            loadThread()
            prepareSession()
            if let initialQuestion { send(initialQuestion) }
            await cyclePrompts()
        }
    }

    private var modelMenu: some View {
        Menu {
            modelButton(.onDevice)
            ForEach(AskProvider.allCases) { provider in
                Section(provider.name) {
                    ForEach(AskModel.allCases.filter { $0.provider == provider }) { model in
                        modelButton(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedModel.name)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("AI model, \(selectedModel.name)")
    }

    private func modelButton(_ model: AskModel) -> some View {
        Button {
            choose(model)
        } label: {
            if model == selectedModel {
                Label(model.name, systemImage: "checkmark")
            } else {
                Text(model.name)
            }
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture { composerFocused = false }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(messages) { message in
                            bubble(message)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .id(message.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .simultaneousGesture(TapGesture().onEnded {
                        composerFocused = false
                    })
                    .onChange(of: messages.last?.text) { _, _ in
                        if let last = messages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    // A reopened chat starts at its latest message. The list has no rows to scroll
                    // to until its first layout, so this waits a moment.
                    .task {
                        try? await Task.sleep(for: .milliseconds(150))
                        if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            if !isSending, !followUps.isEmpty || !tryModels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tryModels) { model in
                            Button("Try with \(model.name)") { tryAgain(with: model) }
                                .buttonStyle(.borderedProminent)
                                // AccentColor is ink, light in Dark, and the default label vanishes on it.
                                .foregroundStyle(Color(.systemBackground))
                        }
                        ForEach(followUps, id: \.self) { tip in
                            Button(tip) { send(tip) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            }

            composer
        }
        .padding(.horizontal)
    }

    private var composer: some View {
        HStack {
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text(promptHints[promptIndex])
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .writingToolsBehavior(.complete)
                    .focused($composerFocused)
                    // A multi-line field takes Return as a new line and never reports the key, so
                    // a typed line break is the only sign of it. Pasted text keeps its lines.
                    .onChange(of: draft) { old, new in
                        guard GCKeyboard.coalesced != nil, new.count == old.count + 1,
                              new.filter(\.isNewline).count > old.filter(\.isNewline).count
                        else { return }
                        draft = old
                        send(old)
                    }
            }
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding()
        .background { ComposerOrbit() }
        .padding(.vertical, 14)
    }

    private func bubble(_ message: AskBubble) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty {
                    ProgressView()
                } else {
                    Text(message.text)
                }
                if let caption = caption(for: message) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(message.remembered, id: \.self) { note in
                    Label("Remembered: \(note)", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let warning = message.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(message.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    private func caption(for message: AskBubble) -> String? {
        guard let name = message.modelName else { return nil }
        guard let seconds = message.seconds else { return name }
        return "\(name) · \(seconds.formatted(.number.precision(.fractionLength(1))))s"
    }

    /// The other models to compare, once the last question has an answer.
    private var tryModels: [AskModel] {
        guard let last = messages.last, !last.isUser else { return [] }
        let answered = AskModel.allCases.first { $0.name == last.modelName } ?? selectedModel
        return answered.alternatives()
    }

    private func choose(_ model: AskModel) {
        guard model.isReady else {
            setupRequest = AskSetupRequest(model: model, tryingQuestion: false)
            return
        }
        select(model)
    }

    private func select(_ model: AskModel) {
        AskModel.selected = model
        selectedModel = model
    }

    private func finishSetup(_ request: AskSetupRequest) {
        setupRequest = nil
        if request.tryingQuestion {
            tryAgain(with: request.model)
        } else {
            select(request.model)
        }
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        composerFocused = false
        draft = ""
        let history = chatHistory(messages)
        messages.append(AskBubble(id: UUID(), isUser: true, text: text))
        persist(text: text, isUser: true)
        answer(text, history: history, model: selectedModel)
    }

    /// Asks the last question again on another model, and keeps both answers.
    private func tryAgain(with model: AskModel) {
        guard !isSending, let index = messages.lastIndex(where: \.isUser) else { return }
        guard model.isReady else {
            setupRequest = AskSetupRequest(model: model, tryingQuestion: true)
            return
        }
        answer(messages[index].text, history: chatHistory(Array(messages[..<index])), model: model)
    }

    private func answer(_ question: String, history: [AskChatTurn], model: AskModel) {
        followUps = []
        let assistantID = UUID()
        messages.append(AskBubble(id: assistantID, isUser: false, text: "", modelName: model.name))
        isSending = true
        let started = Date()
        Task {
            defer { isSending = false }
            let setText = { (value: String) in
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].text = value
                }
            }
            do {
                let reply = try await reply(to: question, history: history, model: model, onText: setText)
                let seconds = Date().timeIntervalSince(started)
                setText(reply.text)
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].warning = reply.warning
                    messages[index].seconds = seconds
                    messages[index].remembered = reply.remembered
                }
                persist(text: reply.text, isUser: false, modelName: model.name, seconds: seconds)
                followUps = reply.followUps
            } catch {
                setText(AskConversation.message(for: error))
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].failed = true
                }
            }
        }
    }

    private func reply(
        to question: String,
        history: [AskChatTurn],
        model: AskModel,
        onText: @escaping (String) -> Void
    ) async throws -> AskReply {
        if model.provider != nil {
            // An on-device session wouldn't know about this answer, so the next one starts fresh.
            conversation = nil
            return try await AskCloudChat.send(question, history: history, model: model, modelContext: financeContext)
        }
        switch OnDeviceAI.availabilityStatus() {
        case .available:
            return try await activeConversation().send(question, history: history, onText: onText)
        case .unavailable(let reason), .notEnabled(let reason):
            throw OnDeviceAIError.modelUnavailable(reason)
        }
    }

    private func chatHistory(_ bubbles: [AskBubble]) -> [AskChatTurn] {
        bubbles.filter { !$0.text.isEmpty && !$0.failed }.map { AskChatTurn(isUser: $0.isUser, text: $0.text) }
    }

    private func activeConversation() -> AskConversation {
        if let conversation { return conversation }
        let created = AskConversation(modelContext: financeContext)
        conversation = created
        return created
    }

    private func prepareSession() {
        guard selectedModel == .onDevice, case .available = OnDeviceAI.availabilityStatus() else { return }
        activeConversation().prepare(history: chatHistory(messages))
    }

    private func loadThread() {
        var descriptor = FetchDescriptor<AskThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let existing = try? askContext.fetch(descriptor).first {
            thread = existing
            messages = existing.turns
                .sorted { $0.createdAt < $1.createdAt }
                .map {
                    AskBubble(id: UUID(), isUser: $0.isUser, text: $0.text, modelName: $0.modelName, seconds: $0.seconds)
                }
        } else {
            let fresh = AskThread()
            askContext.insert(fresh)
            thread = fresh
            try? askContext.save()
        }
    }

    private func persist(text: String, isUser: Bool, modelName: String? = nil, seconds: Double? = nil) {
        guard let thread else { return }
        let turn = AskTurn(isUser: isUser, text: text, modelName: modelName, seconds: seconds, thread: thread)
        askContext.insert(turn)
        thread.updatedAt = .now
        try? askContext.save()
    }

    private func clearChat() {
        AskStore.wipe()
        messages = []
        followUps = []
        conversation = nil
        loadThread()
        prepareSession()
    }

    private func cyclePrompts() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.5))
            guard draft.isEmpty else { continue }
            withAnimation(.easeInOut(duration: 0.5)) {
                promptIndex = (promptIndex + 1) % promptHints.count
            }
        }
    }
}

/// Four-color conic wash, clipped to the field; the same ring is blurred outside as the glow.
private struct ComposerOrbit: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / 7
            let angle = Angle.degrees((turns - floor(turns)) * 360)
            let ring = AngularGradient(
                colors: [.cyan, .purple, .pink, .orange, .cyan],
                center: .center,
                angle: angle
            )
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(ring)
                    .blur(radius: 12)
                    .opacity(0.45)
                    .padding(-7)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.background.opacity(0.9))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ring)
                    .opacity(0.28)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ring, lineWidth: 2)
            }
        }
    }
}

#Preview {
    OnDeviceAIChatView()
}
