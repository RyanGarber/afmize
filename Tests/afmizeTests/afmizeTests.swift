import Foundation
import FoundationModels
import Testing

@testable import afmize

// MARK: - Request decoding

@Test func decodesFullRequest() throws {
    let json = """
    {
      "model": "private-cloud-compute",
      "temperature": 0.5,
      "maximumResponseTokens": 512,
      "reasoningLevel": "deep",
      "toolChoice": "auto",
      "tools": [
        {
          "name": "get_weather",
          "description": "Get the weather",
          "inputSchema": {
            "type": "object",
            "properties": { "city": { "type": "string" } },
            "required": ["city"]
          }
        }
      ],
      "messages": [
        { "role": "system", "parts": [ { "type": "text", "text": "Be brief." } ] },
        { "role": "user", "parts": [ { "type": "text", "text": "Weather in Paris?" } ] },
        {
          "role": "assistant",
          "parts": [
            { "type": "reasoning", "text": "User wants weather." },
            { "type": "tool-call", "toolCallId": "call-1", "toolName": "get_weather", "input": { "city": "Paris" } }
          ]
        },
        {
          "role": "tool",
          "parts": [
            {
              "type": "tool-result",
              "toolCallId": "call-1",
              "toolName": "get_weather",
              "output": { "type": "json", "value": { "temperature": 21 } }
            }
          ]
        }
      ]
    }
    """
    let request = try JSONDecoder().decode(AfmRequest.self, from: Data(json.utf8))
    #expect(request.model == .privateCloudCompute)
    #expect(request.messages.count == 4)
    #expect(request.tools?.count == 1)
    #expect(request.tools?.first?.name == "get_weather")
    #expect(request.messages[2].parts[1].type == .toolCall)
    #expect(request.messages[2].parts[1].input?.objectValue?["city"]?.stringValue == "Paris")
}

// MARK: - Schema conversion

@Test func convertsJSONSchemaToGenerationSchema() throws {
    let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "city": .object(["type": .string("string"), "description": .string("City name")]),
            "unit": .object(["type": .string("string"), "enum": .array([.string("c"), .string("f")])]),
            "days": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(10)]),
            "coords": .object([
                "type": .string("object"),
                "properties": .object([
                    "lat": .object(["type": .string("number")]),
                    "lon": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("lat"), .string("lon")]),
            ]),
            "tags": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "maxItems": .number(5),
            ]),
            "verbose": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("city")]),
    ])

    let generated = try SchemaConversion.generationSchema(name: "get_weather", jsonSchema: schema)
    let dump = generated.debugDescription
    #expect(dump.contains("city"))
    #expect(dump.contains("coords"))
}

@Test func convertsEmptyAndAnyOfSchemas() throws {
    _ = try SchemaConversion.generationSchema(name: "no_args", jsonSchema: nil)
    _ = try SchemaConversion.generationSchema(
        name: "choice",
        jsonSchema: .object([
            "anyOf": .array([
                .object(["type": .string("string")]),
                .object([
                    "type": .string("object"),
                    "properties": .object(["x": .object(["type": .string("number")])]),
                ]),
            ])
        ])
    )
}

// MARK: - Transcript building

private func entryKinds(_ transcript: Transcript) -> [String] {
    transcript.map { entry in
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .response: "response"
        case .reasoning: "reasoning"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        @unknown default: "unknown"
        }
    }
}

@Test func buildsTranscriptWithTrailingUserPrompt() throws {
    let messages: [AfmMessage] = [
        AfmMessage(role: .system, parts: [AfmPart(type: .text, text: "Be helpful.")]),
        AfmMessage(role: .user, parts: [AfmPart(type: .text, text: "Hi")]),
        AfmMessage(role: .assistant, parts: [AfmPart(type: .text, text: "Hello!")]),
        AfmMessage(role: .user, parts: [AfmPart(type: .text, text: "What's 2+2?")]),
    ]
    let built = try TranscriptBuilder.build(messages: messages, toolDefinitions: [])
    // The trailing user message becomes the prompt, not a transcript entry.
    #expect(entryKinds(built.transcript) == ["instructions", "prompt", "response"])
}

@Test func buildsToolContinuationTranscript() throws {
    let toolDefinition = Transcript.ToolDefinition(
        name: "get_weather",
        description: "Get the weather",
        parameters: try SchemaConversion.generationSchema(name: "get_weather", jsonSchema: nil)
    )
    let messages: [AfmMessage] = [
        AfmMessage(role: .user, parts: [AfmPart(type: .text, text: "Weather in Paris?")]),
        AfmMessage(
            role: .assistant,
            parts: [
                AfmPart(type: .reasoning, text: "Need to call the tool."),
                AfmPart(
                    type: .toolCall,
                    toolCallId: "call-1",
                    toolName: "get_weather",
                    input: .object(["city": .string("Paris")])
                ),
            ]
        ),
        AfmMessage(
            role: .tool,
            parts: [
                AfmPart(
                    type: .toolResult,
                    toolCallId: "call-1",
                    toolName: "get_weather",
                    output: .object(["type": .string("json"), "value": .object(["temp": .number(21)])])
                )
            ]
        ),
    ]
    let built = try TranscriptBuilder.build(messages: messages, toolDefinitions: [toolDefinition])
    #expect(entryKinds(built.transcript) == ["instructions", "prompt", "reasoning", "toolCalls", "toolOutput"])

    // The tool call arguments must round-trip through GeneratedContent.
    guard case .toolCalls(let calls) = built.transcript[3] else {
        Issue.record("expected toolCalls entry")
        return
    }
    #expect(calls.count == 1)
    #expect(calls[0].id == "call-1")
    #expect(calls[0].toolName == "get_weather")
    #expect(calls[0].arguments.jsonString.contains("Paris"))
}

@Test func groupsAssistantPartsInOrder() throws {
    let messages: [AfmMessage] = [
        AfmMessage(
            role: .assistant,
            parts: [
                AfmPart(type: .reasoning, text: "thinking..."),
                AfmPart(type: .text, text: "part one. "),
                AfmPart(type: .text, text: "part two."),
                AfmPart(type: .toolCall, toolCallId: "a", toolName: "t", input: .object([:])),
                AfmPart(type: .toolCall, toolCallId: "b", toolName: "t", input: .object([:])),
            ]
        )
    ]
    let built = try TranscriptBuilder.build(messages: messages, toolDefinitions: [])
    #expect(entryKinds(built.transcript) == ["reasoning", "response", "toolCalls"])
    guard case .toolCalls(let calls) = built.transcript[2] else {
        Issue.record("expected toolCalls entry")
        return
    }
    #expect(calls.map(\.id) == ["a", "b"])
}

@Test func rejectsInvalidParts() {
    #expect(throws: AfmSetupError.self) {
        _ = try TranscriptBuilder.build(
            messages: [
                AfmMessage(role: .user, parts: [AfmPart(type: .toolResult, toolCallId: "x")])
            ],
            toolDefinitions: []
        )
    }
    #expect(throws: AfmSetupError.self) {
        _ = try TranscriptBuilder.build(
            messages: [
                AfmMessage(
                    role: .user,
                    parts: [AfmPart(type: .file, mediaType: "application/pdf", data: "AAAA")]
                ),
                AfmMessage(role: .user, parts: [AfmPart(type: .text, text: "hi")]),
            ],
            toolDefinitions: []
        )
    }
}

// MARK: - Tool input/output normalization

@Test func normalizesToolCallInput() {
    #expect(TranscriptBuilder.toolCallInputJSON(nil) == "{}")
    #expect(TranscriptBuilder.toolCallInputJSON(.object(["a": .number(1)])) == #"{"a":1}"#)
    #expect(TranscriptBuilder.toolCallInputJSON(.string(#"{"a":1}"#)) == #"{"a":1}"#)
    #expect(TranscriptBuilder.toolCallInputJSON(.string("plain")) == #""plain""#)
}

@Test func normalizesToolResultOutput() {
    #expect(TranscriptBuilder.toolOutputText(nil) == "")
    #expect(TranscriptBuilder.toolOutputText(.string("hello")) == "hello")
    #expect(
        TranscriptBuilder.toolOutputText(
            .object(["type": .string("text"), "value": .string("sunny")])
        ) == "sunny"
    )
    #expect(
        TranscriptBuilder.toolOutputText(
            .object(["type": .string("json"), "value": .object(["temp": .number(21)])])
        ) == #"{"temp":21}"#
    )
    #expect(
        TranscriptBuilder.toolOutputText(.object(["temp": .number(21)])) == #"{"temp":21}"#
    )
}

// MARK: - Events

@Test func encodesEvents() {
    #expect(AfmEvent.streamStart().jsonString() == #"{"type":"stream-start"}"#)
    #expect(
        AfmEvent.textDelta(id: "text-0", delta: "hi").jsonString()
            == #"{"delta":"hi","id":"text-0","type":"text-delta"}"#
    )
    #expect(
        AfmEvent.toolCall(id: "c1", name: "get_weather", input: #"{"city":"Paris"}"#).jsonString()
            == #"{"input":"{\"city\":\"Paris\"}","toolCallId":"c1","toolName":"get_weather","type":"tool-call"}"#
    )
    let finish = AfmEvent.finish(
        reason: "stop",
        usage: AfmUsage(inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningTokens: 1, totalTokens: 15)
    ).jsonString()
    #expect(finish.contains(#""finishReason":"stop""#))
    #expect(finish.contains(#""inputTokens":10"#))
}

@Test func classifiesToolInterrupt() {
    #expect(Afmize.isToolInterrupt(AfmToolInterrupt()))
    #expect(!Afmize.isToolInterrupt(CancellationError()))
}

// MARK: - Availability

@Test func availabilityJSONIsWellFormed() throws {
    let json = Afmize.availabilityJSON()
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    #expect(object?["onDevice"] != nil)
    #expect(object?["privateCloudCompute"] != nil)
}

// MARK: - Live smoke tests (skipped when Apple Intelligence is unavailable)

private func collectEvents(_ requestJSON: String) async -> [AfmEvent] {
    var events: [AfmEvent] = []
    for await json in Afmize.eventStream(requestJSON: requestJSON) {
        if let event = try? JSONDecoder().decode(AfmEvent.self, from: Data(json.utf8)) {
            events.append(event)
        }
    }
    return events
}

@Test(.enabled(if: SystemLanguageModel.default.isAvailable))
func liveTextStreaming() async throws {
    let request = """
    {
      "model": "on-device",
      "messages": [
        { "role": "user", "parts": [ { "type": "text", "text": "Reply with exactly the word OK." } ] }
      ]
    }
    """
    let events = await collectEvents(request)
    #expect(events.first?.type == "stream-start")
    #expect(events.last?.type == "finish")
    #expect(events.last?.finishReason == "stop")
    #expect(events.contains { $0.type == "text-delta" })
    #expect((events.last?.usage?.totalTokens ?? 0) > 0)
}

@Test(.enabled(if: SystemLanguageModel.default.isAvailable))
func liveToolCallInterrupt() async throws {
    let request = """
    {
      "model": "on-device",
      "toolChoice": "required",
      "tools": [
        {
          "name": "get_weather",
          "description": "Get the current weather for a city.",
          "inputSchema": {
            "type": "object",
            "properties": { "city": { "type": "string", "description": "City name" } },
            "required": ["city"]
          }
        }
      ],
      "messages": [
        { "role": "user", "parts": [ { "type": "text", "text": "What is the weather in Paris right now?" } ] }
      ]
    }
    """
    let events = await collectEvents(request)
    #expect(events.first?.type == "stream-start")
    #expect(events.last?.type == "finish")
    #expect(events.last?.finishReason == "tool-calls")
    let toolCalls = events.filter { $0.type == "tool-call" }
    #expect(toolCalls.count >= 1)
    #expect(toolCalls.first?.toolName == "get_weather")
    #expect(toolCalls.first?.toolCallId?.isEmpty == false)
    #expect(toolCalls.first?.input?.contains("Paris") == true)
}

@Test(.enabled(if: SystemLanguageModel.default.isAvailable))
func liveToolResultContinuation() async throws {
    let request = """
    {
      "model": "on-device",
      "tools": [
        {
          "name": "get_weather",
          "description": "Get the current weather for a city.",
          "inputSchema": {
            "type": "object",
            "properties": { "city": { "type": "string" } },
            "required": ["city"]
          }
        }
      ],
      "messages": [
        { "role": "user", "parts": [ { "type": "text", "text": "What is the weather in Paris right now?" } ] },
        {
          "role": "assistant",
          "parts": [
            { "type": "tool-call", "toolCallId": "call-1", "toolName": "get_weather", "input": { "city": "Paris" } }
          ]
        },
        {
          "role": "tool",
          "parts": [
            {
              "type": "tool-result",
              "toolCallId": "call-1",
              "toolName": "get_weather",
              "output": { "type": "json", "value": { "temperatureCelsius": 21, "condition": "sunny" } }
            }
          ]
        }
      ]
    }
    """
    let events = await collectEvents(request)
    #expect(events.last?.type == "finish")
    #expect(events.last?.finishReason == "stop")
    let text = events.filter { $0.type == "text-delta" }.compactMap(\.delta).joined()
    #expect(!text.isEmpty)
}
