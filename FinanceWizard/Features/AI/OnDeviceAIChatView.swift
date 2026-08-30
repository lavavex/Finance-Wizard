//
//  OnDeviceAIChatView.swift
//  Finance Wizard
//
//  On-device Ask chat: streaming, tools, prewarm, persisted thread.
//

import SwiftData
import SwiftUI
import FoundationModels

private struct AskBubble: Identifiable {
    let id: UUID
    let isUser: Bool
    var text: String
}

struct OnDeviceAIChatView: View {
    @Environment(\.modelContext) private var financeContext

    @State private var draft = ""
    @State private var messages: [AskBubble] = []
    @FocusState private var composerFocused: Bool
    @State private var followUps: [String] = []
    @State private var promptIndex = 0
    @State private var session: LanguageModelSession?
    @State private var isSending = false
    @State private var thread: AskThread?
    @State private var askContext = ModelContext(AskStore.container)

    private let promptHints = [
        "What's my biggest category?",
        "How much did I spend this month?",
        "What recurring charges are coming up?",
    ]

    private var availability: OnDeviceAIAvailability { OnDeviceAI.availabilityStatus() }

    var body: some View {
        NavigationStack {
            Group {
                switch availability {
                case .available:
                    chatBody
                case .unavailable(let reason), .notEnabled(let reason):
                    ContentUnavailableView(
                        "On-device AI unavailable",
                        systemImage: "apple.intelligence.badge.xmark",
                        description: Text(reason)
                    )
                }
            }
        }
        .task {
            loadThread()
            prepareSession()
            await cyclePrompts()
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
                }
            }

            if !followUps.isEmpty, !isSending {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
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
            Text(message.text)
                .padding(10)
                .background(message.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        composerFocused = false
        draft = ""
        followUps = []
        let user = AskBubble(id: UUID(), isUser: true, text: text)
        messages.append(user)
        persist(text: text, isUser: true)
        let assistantID = UUID()
        messages.append(AskBubble(id: assistantID, isUser: false, text: ""))
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try rotateSessionIfNeeded()
                if session == nil {
                    session = try OnDeviceAI.makeAskSession(modelContext: financeContext)
                    session?.prewarm()
                }
                guard let session else { return }
                let stream = session.streamResponse(to: text)
                var answer = ""
                for try await snapshot in stream {
                    answer = snapshot.content
                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].text = answer
                    }
                }
                answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty {
                    throw OnDeviceAIError.emptyResponse
                }
                persist(text: answer, isUser: false)
                followUps = [
                    "Compare to last month",
                    "What are my account balances?",
                    "What recurring charges do I have?",
                ]
            } catch {
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].text = error.localizedDescription
                }
            }
        }
    }

    private func prepareSession() {
        guard case .available = availability else { return }
        do {
            if session == nil {
                session = try OnDeviceAI.makeAskSession(modelContext: financeContext)
            }
            session?.prewarm()
        } catch {
            // Availability UI covers this.
        }
    }

    private func rotateSessionIfNeeded() throws {
        guard let session else { return }
        let count = session.transcript.count
        if count > 28 {
            self.session = try OnDeviceAI.makeAskSession(modelContext: financeContext)
            self.session?.prewarm()
        }
    }

    private func loadThread() {
        var descriptor = FetchDescriptor<AskThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let existing = try? askContext.fetch(descriptor).first {
            thread = existing
            messages = existing.turns
                .sorted { $0.createdAt < $1.createdAt }
                .map { AskBubble(id: UUID(), isUser: $0.isUser, text: $0.text) }
        } else {
            let fresh = AskThread()
            askContext.insert(fresh)
            thread = fresh
            try? askContext.save()
        }
    }

    private func persist(text: String, isUser: Bool) {
        guard let thread else { return }
        let turn = AskTurn(isUser: isUser, text: text, thread: thread)
        askContext.insert(turn)
        thread.updatedAt = .now
        try? askContext.save()
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
