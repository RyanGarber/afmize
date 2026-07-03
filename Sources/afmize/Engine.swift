import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tool interruption

/// Thrown from `ProxyTool.call` to end the turn at the tool-call boundary.
/// Tools are never executed on the Swift side; the host app runs them and
/// starts a new request with tool-result parts appended.
struct AfmToolInterrupt: Error {}

/// A tool that only exists so the model can call it. Calling it always
/// interrupts the stream.
struct ProxyTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema

    var includesSchemaInInstructions: Bool { true }

    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        throw AfmToolInterrupt()
    }
}

// MARK: - Engine

public enum Afmize {
    // MARK: Availability

    /// Returns a JSON report of on-device and Private Cloud Compute
    /// availability, e.g.
    /// `{"onDevice":{"available":true},"privateCloudCompute":{"available":false,"reason":"device-not-eligible"}}`.
    public static func availabilityJSON() -> String {
        struct Status: Encodable {
            var available: Bool
            var reason: String?
        }
        struct Report: Encodable {
            var onDevice: Status
            var privateCloudCompute: Status
        }

        let onDevice: Status
        switch SystemLanguageModel.default.availability {
        case .available:
            onDevice = Status(available: true)
        case .unavailable(let reason):
            onDevice = Status(available: false, reason: describe(reason))
        }

        let cloud: Status
        switch PrivateCloudComputeLanguageModel().availability {
        case .available:
            cloud = Status(available: true)
        case .unavailable(let reason):
            cloud = Status(available: false, reason: describe(reason))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let report = Report(onDevice: onDevice, privateCloudCompute: cloud)
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Entry points

    /// Runs a request and yields each event as a JSON string. The stream
    /// always starts with `stream-start` and ends with `finish`.
    public static func eventStream(requestJSON: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                await run(requestJSON: requestJSON) { event in
                    continuation.yield(event.jsonString())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func run(
        requestJSON: String,
        emit: @escaping @Sendable (AfmEvent) -> Void
    ) async {
        let request: AfmRequest
        do {
            request = try JSONDecoder().decode(AfmRequest.self, from: Data(requestJSON.utf8))
        } catch {
            emit(.streamStart())
            emit(.error(code: "invalid-request", message: "failed to decode request: \(error)"))
            emit(.finish(reason: "error", usage: nil))
            return
        }
        await run(request: request, emit: emit)
    }

    public static func run(
        request: AfmRequest,
        emit: @escaping @Sendable (AfmEvent) -> Void
    ) async {
        emit(.streamStart())

        let session: LanguageModelSession
        let prompt: Prompt
        let hasTools = !(request.tools ?? []).isEmpty
        do {
            let tools = try (request.tools ?? []).map { definition in
                ProxyTool(
                    name: definition.name,
                    description: definition.description ?? "",
                    parameters: try SchemaConversion.generationSchema(
                        name: definition.name,
                        jsonSchema: definition.inputSchema
                    )
                )
            }
            let toolDefinitions = tools.map {
                Transcript.ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
            }
            let built = try TranscriptBuilder.build(
                messages: request.messages,
                toolDefinitions: toolDefinitions
            )
            prompt = built.prompt
            session = try makeSession(request: request, tools: tools, transcript: built.transcript)
        } catch {
            let (code, message) = classify(error)
            emit(.error(code: code, message: message))
            emit(.finish(reason: "error", usage: nil))
            return
        }

        await stream(session: session, prompt: prompt, request: request, hasTools: hasTools, emit: emit)
    }

    // MARK: Session setup

    private static func makeSession(
        request: AfmRequest,
        tools: [ProxyTool],
        transcript: Transcript
    ) throws -> LanguageModelSession {
        switch request.model {
        case .onDevice:
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = model.availability {
                throw AfmSetupError.modelUnavailable("on-device model unavailable: \(describe(reason))")
            }
            return LanguageModelSession(model: model, tools: tools, transcript: transcript)
        case .privateCloudCompute:
            let model = PrivateCloudComputeLanguageModel()
            if case .unavailable(let reason) = model.availability {
                throw AfmSetupError.modelUnavailable("Private Cloud Compute unavailable: \(describe(reason))")
            }
            return LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "device-not-eligible"
        case .appleIntelligenceNotEnabled: "apple-intelligence-not-enabled"
        case .modelNotReady: "model-not-ready"
        @unknown default: "unknown"
        }
    }

    private static func describe(
        _ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible: "device-not-eligible"
        case .systemNotReady: "system-not-ready"
        @unknown default: "unknown"
        }
    }

    // MARK: Streaming

    private struct DiffState {
        var lastText = ""
        var reasoning: [String: String] = [:]
        var emittedToolCallIDs: Set<String> = []
        var emittedFileIDs: Set<String> = []
    }

    private static func stream(
        session: LanguageModelSession,
        prompt: Prompt,
        request: AfmRequest,
        hasTools: Bool,
        emit: @escaping @Sendable (AfmEvent) -> Void
    ) async {
        // Keep the transcript (including the model's tool-calls entry) when a
        // proxy tool interrupts the turn, so the calls can be read back.
        session.transcriptErrorHandlingPolicy = .preserveTranscript

        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maximumResponseTokens,
            toolCallingMode: toolCallingMode(request.toolChoice, hasTools: hasTools)
        )
        let contextOptions = ContextOptions(reasoningLevel: reasoningLevel(request.reasoningLevel))

        let baselineEntryCount = session.transcript.count
        var state = DiffState()
        var usage: LanguageModelSession.Usage?

        let stream = session.streamResponse(to: prompt, options: options, contextOptions: contextOptions)
        do {
            for try await snapshot in stream {
                usage = snapshot.usage
                emitDiffs(snapshot: snapshot, state: &state, emit: emit)
            }
            emit(.finish(reason: "stop", usage: usage.map(mapUsage)))
        } catch is CancellationError {
            emit(.finish(reason: "other", usage: usage.map(mapUsage)))
        } catch {
            if isToolInterrupt(error) {
                emitPendingToolCalls(
                    session: session,
                    baseline: baselineEntryCount,
                    state: &state,
                    emit: emit
                )
                emit(.finish(reason: "tool-calls", usage: usage.map(mapUsage)))
            } else {
                let (code, message) = classify(error)
                emit(.error(code: code, message: message))
                emit(.finish(reason: "error", usage: usage.map(mapUsage)))
            }
        }
    }

    private static func emitDiffs(
        snapshot: LanguageModelSession.ResponseStream<String>.Snapshot,
        state: inout DiffState,
        emit: (AfmEvent) -> Void
    ) {
        for entry in snapshot.transcriptEntries {
            switch entry {
            case .reasoning(let reasoning):
                let full = reasoning.segments
                    .compactMap { segment -> String? in
                        if case .text(let text) = segment { return text.content }
                        return nil
                    }
                    .joined()
                let previous = state.reasoning[reasoning.id] ?? ""
                guard full != previous else { break }
                if full.hasPrefix(previous) {
                    emit(.reasoningDelta(id: reasoning.id, delta: String(full.dropFirst(previous.count))))
                } else {
                    emit(.reasoningReplace(id: reasoning.id, text: full))
                }
                state.reasoning[reasoning.id] = full

            case .toolCalls(let calls):
                for call in calls where !state.emittedToolCallIDs.contains(call.id) {
                    state.emittedToolCallIDs.insert(call.id)
                    emit(.toolCall(id: call.id, name: call.toolName, input: call.arguments.jsonString))
                }

            case .response(let response):
                for segment in response.segments {
                    if case .attachment(let attachment) = segment,
                       !state.emittedFileIDs.contains(attachment.id) {
                        state.emittedFileIDs.insert(attachment.id)
                        if let event = fileEvent(from: attachment) {
                            emit(event)
                        }
                    }
                }

            default:
                break
            }
        }

        let text = snapshot.content
        if text != state.lastText {
            if text.hasPrefix(state.lastText) {
                emit(.textDelta(id: "text-0", delta: String(text.dropFirst(state.lastText.count))))
            } else {
                emit(.textReplace(id: "text-0", text: text))
            }
            state.lastText = text
        }
    }

    /// After a tool interrupt, reads all tool calls of the turn from the
    /// preserved transcript and emits any that were not already streamed.
    private static func emitPendingToolCalls(
        session: LanguageModelSession,
        baseline: Int,
        state: inout DiffState,
        emit: (AfmEvent) -> Void
    ) {
        let transcript = session.transcript
        guard transcript.count > baseline else { return }
        for entry in transcript.dropFirst(baseline) {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls where !state.emittedToolCallIDs.contains(call.id) {
                state.emittedToolCallIDs.insert(call.id)
                emit(.toolCall(id: call.id, name: call.toolName, input: call.arguments.jsonString))
            }
        }
    }

    // MARK: Options mapping

    private static func toolCallingMode(
        _ choice: AfmToolChoice?,
        hasTools: Bool
    ) -> GenerationOptions.ToolCallingMode? {
        guard hasTools else { return nil }
        switch choice {
        case .some(.none): return .disallowed
        case .some(.required): return .required
        case .some(.auto), nil: return .allowed
        }
    }

    private static func reasoningLevel(_ raw: String?) -> ContextOptions.ReasoningLevel? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "light": return .light
        case "moderate": return .moderate
        case "deep": return .deep
        default: return .custom(raw)
        }
    }

    private static func mapUsage(_ usage: LanguageModelSession.Usage) -> AfmUsage {
        AfmUsage(
            inputTokens: usage.input.totalTokenCount,
            cachedInputTokens: usage.input.cachedTokenCount,
            outputTokens: usage.output.totalTokenCount,
            reasoningTokens: usage.output.reasoningTokenCount,
            totalTokens: usage.totalTokenCount
        )
    }

    // MARK: Files

    private static func fileEvent(from segment: Transcript.AttachmentSegment) -> AfmEvent? {
        switch segment.content {
        case .image(let image):
            if let url = image.url {
                return .file(mediaType: mediaType(forImageURL: url), data: url.absoluteString)
            }
            if let base64 = pngBase64(from: image.cgImage) {
                return .file(mediaType: "image/png", data: base64)
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private static func mediaType(forImageURL url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
    }

    private static func pngBase64(from image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data).base64EncodedString()
    }

    // MARK: Errors

    static func isToolInterrupt(_ error: any Error) -> Bool {
        if error is AfmToolInterrupt { return true }
        if let toolCallError = error as? LanguageModelSession.ToolCallError {
            return isToolInterrupt(toolCallError.underlyingError)
        }
        return false
    }

    static func classify(_ error: any Error) -> (code: String, message: String) {
        switch error {
        case let setupError as AfmSetupError:
            return setupError.codeAndMessage

        case let toolCallError as LanguageModelSession.ToolCallError:
            return classify(toolCallError.underlyingError)

        case let modelError as LanguageModelError:
            let code: String
            switch modelError {
            case .contextSizeExceeded: code = "context-size-exceeded"
            case .rateLimited: code = "rate-limited"
            case .guardrailViolation: code = "guardrail-violation"
            case .refusal: code = "refusal"
            case .unsupportedCapability: code = "unsupported-capability"
            case .unsupportedTranscriptContent: code = "unsupported-transcript-content"
            case .unsupportedGenerationGuide: code = "unsupported-generation-guide"
            case .unsupportedLanguageOrLocale: code = "unsupported-language-or-locale"
            case .timeout: code = "timeout"
            @unknown default: code = "language-model-error"
            }
            return (code, modelError.debugDescription)

        case let cloudError as PrivateCloudComputeLanguageModel.Error:
            let code: String
            switch cloudError {
            case .networkFailure: code = "pcc-network-failure"
            case .quotaLimitReached: code = "pcc-quota-limit-reached"
            case .serviceUnavailable: code = "pcc-service-unavailable"
            @unknown default: code = "pcc-error"
            }
            return (code, cloudError.debugDescription)

        case let systemError as SystemLanguageModel.Error:
            return ("assets-unavailable", systemError.debugDescription)

        case let sessionError as LanguageModelSession.Error:
            let code: String
            switch sessionError {
            case .concurrentRequests: code = "concurrent-requests"
            case .transcriptMutationWhileResponding: code = "transcript-mutation-while-responding"
            @unknown default: code = "session-error"
            }
            return (code, sessionError.debugDescription)

        case let parsingError as GeneratedContent.ParsingError:
            return ("parsing-error", parsingError.debugDescription)

        default:
            return ("unknown", String(describing: error))
        }
    }
}
