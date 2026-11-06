//
//  AskCloudChatTests.swift
//  Finance Wizard
//
//  Ask's Claude and Grok requests against canned responses. Nothing here reaches a provider.
//

import XCTest
import FoundationModels
import SwiftData
@testable import FinanceWizard

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        let next = Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class AskCloudChatTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var session: URLSession!

    override func setUpWithError() throws {
        container = try SharedStore.makeContainer(inMemory: true)
        context = ModelContext(container)
        let row = Transaction(
            transactionId: "row",
            title: "Example Market",
            amount: -25,
            date: Date(),
            category: "Groceries",
            paymentMethod: "Card"
        )
        context.insert(row)
        try context.save()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.responses = []
        StubProtocol.requests = []
        StubProtocol.bodies = []
    }

    private func send(_ model: AskModel, history: [AskChatTurn] = []) async throws -> AskReply {
        try await AskCloudChat.send(
            "How much at Example Market?",
            history: history,
            model: model,
            apiKey: "test-key",
            tools: AskCloudTool.all(modelContext: context),
            session: session
        )
    }

    private let spendingArguments = #"{"merchant":"Example Market","fromMonth":""}"#

    // MARK: - Claude

    func testClaudeRunsToolsAndReplaysItsResponse() async throws {
        StubProtocol.responses = [
            (200, """
            {"stop_reason":"tool_use","content":[
              {"type":"thinking","thinking":"","signature":"sig"},
              {"type":"tool_use","id":"toolu_1","name":"getSpending","input":\(spendingArguments)}
            ]}
            """),
            (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"You spent $25.00."}]}"#),
        ]

        let reply = try await send(.claudeOpus)

        XCTAssertEqual(reply.text, "You spent $25.00.")
        XCTAssertNil(reply.warning)
        XCTAssertEqual(StubProtocol.requests[0].url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(StubProtocol.requests[0].value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(StubProtocol.requests[0].value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(StubProtocol.requests[0].value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let first = StubProtocol.bodies[0]
        XCTAssertEqual(first["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(first["fallbacks"] as? String, "default")
        XCTAssertNil(first["temperature"])
        XCTAssertNil(first["tool_choice"])
        let tool = (first["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "getSpending" }
        XCTAssertEqual((tool?["input_schema"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertNil((tool?["input_schema"] as? [String: Any])?["x-order"])

        let messages = try XCTUnwrap(StubProtocol.bodies[1]["messages"] as? [[String: Any]])
        let replayed = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(replayed.first?["signature"] as? String, "sig")
        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.first?["tool_use_id"] as? String, "toolu_1")
        XCTAssertTrue((results.first?["content"] as? String)?.contains("25") == true)
    }

    func testHaikuHasNoFallback() async throws {
        StubProtocol.responses = [(200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"Hi"}]}"#)]
        _ = try await send(.claudeHaiku)
        XCTAssertNil(StubProtocol.bodies[0]["fallbacks"])
        XCTAssertNil(StubProtocol.requests[0].value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testClaudeRefusalIsReported() async {
        StubProtocol.responses = [(200, #"{"stop_reason":"refusal","content":[]}"#)]
        await assertThrows(.refused("Claude Opus 5.5"), model: .claudeOpus)
    }

    // MARK: - Grok

    func testGrokRunsToolsAndContinuesTheResponse() async throws {
        let arguments = String(data: try JSONEncoder().encode(spendingArguments), encoding: .utf8)!
        StubProtocol.responses = [
            (200, """
            {"id":"resp_1","output":[
              {"type":"function_call","name":"getSpending","call_id":"call_1","arguments":\(arguments)}
            ]}
            """),
            (200, #"{"id":"resp_2","output":[{"type":"message","content":[{"type":"output_text","text":"You spent $25.00."}]}]}"#),
        ]

        let reply = try await send(.grok47)

        XCTAssertEqual(reply.text, "You spent $25.00.")
        XCTAssertEqual(StubProtocol.requests[0].url?.absoluteString, "https://api.x.ai/v1/responses")
        XCTAssertEqual(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let tool = (StubProtocol.bodies[0]["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "getSpending" }
        XCTAssertEqual(tool?["type"] as? String, "function")
        XCTAssertNotNil(tool?["parameters"])
        XCTAssertNil(tool?["function"])

        XCTAssertEqual(StubProtocol.bodies[1]["previous_response_id"] as? String, "resp_1")
        let input = try XCTUnwrap(StubProtocol.bodies[1]["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[0]["call_id"] as? String, "call_1")
    }

    func testBadToolArgumentsGoBackToTheModel() async throws {
        StubProtocol.responses = [
            (200, #"{"id":"r1","output":[{"type":"function_call","name":"getSpending","call_id":"c1","arguments":"{}"}]}"#),
            (200, #"{"id":"r2","output":[{"type":"message","content":[{"type":"output_text","text":"Sorry."}]}]}"#),
        ]
        _ = try await send(.grok47)
        let input = try XCTUnwrap(StubProtocol.bodies[1]["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["output"] as? String, "Invalid arguments for getSpending.")
    }

    // MARK: - Shared

    func testInventedAmountGetsAWarning() async throws {
        StubProtocol.responses = [(200, #"{"id":"r","output":[{"type":"message","content":[{"text":"You spent $999.99."}]}]}"#)]
        let reply = try await send(.grok47)
        XCTAssertNotNil(reply.warning)
    }

    func testErrorsAreMappedWithoutTheKey() async {
        StubProtocol.responses = [(401, #"{"error":"bad key test-key"}"#)]
        await assertThrows(.keyRejected("Grok 4.7"), model: .grok47)
        StubProtocol.responses = [(429, "{}")]
        await assertThrows(.rateLimited("Grok 4.7"), model: .grok47)
        StubProtocol.responses = [(500, #"{"error":{"message":"Overloaded"}}"#)]
        await assertThrows(.service("Claude Opus 5.5", status: 500, message: "Overloaded"), model: .claudeOpus)
    }

    func testRunawayToolLoopStops() async {
        let loop = #"{"id":"r","output":[{"type":"function_call","name":"getSpending","call_id":"c","arguments":"{}"}]}"#
        StubProtocol.responses = Array(repeating: (200, loop), count: 6)
        await assertThrows(.tooManySteps("Grok 4.3"), model: .grok43)
    }

    func testHistoryAlternatesAndKeepsTheLatestAnswer() {
        let turns = AskCloudChat.turnsToSend([
            AskChatTurn(isUser: false, text: "stray"),
            AskChatTurn(isUser: true, text: "q1"),
            AskChatTurn(isUser: false, text: "local answer"),
            AskChatTurn(isUser: false, text: "grok answer"),
            AskChatTurn(isUser: true, text: "unanswered"),
        ])
        XCTAssertEqual(turns.map(\.text), ["q1", "grok answer"])
    }

    func testCloudModelsGetEveryOnDeviceToolPlusPlanning() throws {
        let cloud = try AskCloudTool.all(modelContext: context).map(\.name)
        let local = OnDeviceAI.askTools(modelContext: context).map(\.name)
        XCTAssertEqual(Array(cloud.prefix(local.count)), local)
        XCTAssertEqual(Array(cloud.dropFirst(local.count)), ["getMoneyPlan", "rememberFact", "forgetFact"])
    }

    func testOnDevicePromptStaysSeparateFromCoaching() {
        XCTAssertFalse(OnDeviceAI.askInstructions().contains("getMoneyPlan"))
        XCTAssertFalse(OnDeviceAI.askInstructions().contains("rememberFact"))
        XCTAssertTrue(AskCloudChat.instructions().contains("getMoneyPlan"))
    }

    func testPromptsHandleBudgetsAndShortenedEmployers() {
        XCTAssertTrue(AskCloudChat.instructions().contains("making a budget"))
        XCTAssertTrue(AskCloudChat.instructions().contains("payroll code"))
        XCTAssertTrue(OnDeviceAI.askInstructions().contains("make a budget"))
    }

    func testNotesReachTheCloudPrompt() {
        XCTAssertTrue(AskCloudChat.instructions(notes: ["Example Stream is cancelled"]).contains("- Example Stream is cancelled"))
        XCTAssertFalse(AskCloudChat.instructions(notes: []).contains("told you earlier"))
    }

    func testRememberToolSavesAndReportsTheFact() async throws {
        AskNotes.clear()
        defer { AskNotes.clear() }
        let arguments = String(data: try JSONEncoder().encode(#"{"fact":"Example Stream is cancelled"}"#), encoding: .utf8)!
        StubProtocol.responses = [
            (200, "{\"id\":\"r1\",\"output\":[{\"type\":\"function_call\",\"name\":\"rememberFact\",\"call_id\":\"c1\",\"arguments\":\(arguments)}]}"),
            (200, #"{"id":"r2","output":[{"type":"message","content":[{"text":"Got it."}]}]}"#),
        ]
        let reply = try await send(.grok47)
        XCTAssertEqual(reply.remembered, ["Example Stream is cancelled"])
        XCTAssertEqual(AskNotes.all, ["Example Stream is cancelled"])
    }

    func testNotesAreBoundedAndDeduplicated() {
        AskNotes.clear()
        defer { AskNotes.clear() }
        AskNotes.add("Same fact")
        XCTAssertNil(AskNotes.add("same FACT"))
        XCTAssertNil(AskNotes.add("   "))
        XCTAssertEqual(AskNotes.add(String(repeating: "x", count: 500))?.count, AskNotes.maximumLength)
        for index in 0..<40 { AskNotes.add("Fact \(index)") }
        XCTAssertEqual(AskNotes.all.count, AskNotes.maximumCount)
        XCTAssertEqual(AskNotes.remove(matching: "Fact 39"), 1)
    }

    func testSampleDataSavesNoNotes() {
        AskNotes.clear()
        DemoMode.isSampleActive = true
        defer { DemoMode.isSampleActive = false; AskNotes.clear() }
        XCTAssertNil(AskNotes.add("Example fact"))
        XCTAssertTrue(AskNotes.all.isEmpty)
    }

    func testAlternativesOfferOneModelFromEachOtherFamily() {
        XCTAssertEqual(AskModel.onDevice.alternatives().compactMap(\.provider), [.anthropic, .xai])
        XCTAssertEqual(AskModel.grok47.alternatives().first, .onDevice)
        XCTAssertFalse(AskModel.grok47.alternatives().contains { $0.provider == .xai })
    }

    private func assertThrows(
        _ expected: AskCloudError,
        model: AskModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await send(model)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AskCloudError, expected, file: file, line: line)
        }
    }
}
