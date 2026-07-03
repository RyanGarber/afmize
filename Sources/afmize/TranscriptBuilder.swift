import CoreImage
import Foundation
import FoundationModels

enum AfmSetupError: Error {
    case invalidRequest(String)
    case modelUnavailable(String)
    case unsupportedContent(String)
    case invalidImage(String)
    case invalidToolInput(String)

    var codeAndMessage: (code: String, message: String) {
        switch self {
        case .invalidRequest(let message): ("invalid-request", message)
        case .modelUnavailable(let message): ("model-unavailable", message)
        case .unsupportedContent(let message): ("unsupported-content", message)
        case .invalidImage(let message): ("invalid-image", message)
        case .invalidToolInput(let message): ("invalid-tool-input", message)
        }
    }
}

/// Builds a FoundationModels `Transcript` (history) and a `Prompt` (current
/// turn) from an AI SDK-style message list.
enum TranscriptBuilder {
    struct Built {
        var transcript: Transcript
        var prompt: Prompt
    }

    static func build(
        messages: [AfmMessage],
        toolDefinitions: [Transcript.ToolDefinition]
    ) throws -> Built {
        var entries: [Transcript.Entry] = []

        // All system messages are merged into a single instructions entry,
        // which also carries the tool definitions.
        let systemText = try messages
            .filter { $0.role == .system }
            .flatMap { message in
                try message.parts.map { part -> String in
                    guard part.type == .text, let text = part.text else {
                        throw AfmSetupError.unsupportedContent(
                            "system messages may only contain text parts"
                        )
                    }
                    return text
                }
            }
            .joined(separator: "\n\n")

        if !systemText.isEmpty || !toolDefinitions.isEmpty {
            var segments: [Transcript.Segment] = []
            if !systemText.isEmpty {
                segments.append(.text(.init(content: systemText)))
            }
            entries.append(.instructions(.init(segments: segments, toolDefinitions: toolDefinitions)))
        }

        var rest = messages.filter { $0.role != .system }

        // A trailing user message becomes the prompt of the new turn. Anything
        // else (e.g. a trailing tool-result message) stays in the transcript
        // and the turn is started with an empty prompt.
        var trailingUser: AfmMessage?
        if let last = rest.last, last.role == .user {
            trailingUser = rest.removeLast()
        }

        for message in rest {
            switch message.role {
            case .system:
                break
            case .user:
                entries.append(.prompt(.init(segments: try contentSegments(message.parts))))
            case .assistant:
                entries.append(contentsOf: try assistantEntries(message.parts))
            case .tool:
                for part in message.parts {
                    guard part.type == .toolResult else {
                        throw AfmSetupError.unsupportedContent(
                            "tool messages may only contain tool-result parts"
                        )
                    }
                    entries.append(
                        .toolOutput(
                            .init(
                                id: part.toolCallId ?? UUID().uuidString,
                                toolName: part.toolName ?? "",
                                segments: [.text(.init(content: toolOutputText(part.output)))]
                            )
                        )
                    )
                }
            }
        }

        let prompt: Prompt
        if let trailingUser {
            prompt = try promptFrom(parts: trailingUser.parts)
        } else {
            prompt = Prompt("")
        }

        return Built(transcript: Transcript(entries: entries), prompt: prompt)
    }

    // MARK: Assistant messages

    private static func assistantEntries(_ parts: [AfmPart]) throws -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        var reasoningSegments: [Transcript.Segment] = []
        var contentSegments: [Transcript.Segment] = []
        var toolCalls: [Transcript.ToolCall] = []

        func flushReasoning() {
            if !reasoningSegments.isEmpty {
                entries.append(.reasoning(.init(segments: reasoningSegments)))
                reasoningSegments = []
            }
        }
        func flushContent() {
            if !contentSegments.isEmpty {
                entries.append(.response(.init(assetIDs: [], segments: contentSegments)))
                contentSegments = []
            }
        }
        func flushToolCalls() {
            if !toolCalls.isEmpty {
                entries.append(.toolCalls(.init(toolCalls)))
                toolCalls = []
            }
        }

        for part in parts {
            switch part.type {
            case .reasoning:
                flushContent()
                flushToolCalls()
                if let text = part.text, !text.isEmpty {
                    reasoningSegments.append(.text(.init(content: text)))
                }
            case .text:
                flushReasoning()
                flushToolCalls()
                if let text = part.text {
                    contentSegments.append(.text(.init(content: text)))
                }
            case .file:
                flushReasoning()
                flushToolCalls()
                contentSegments.append(.attachment(attachmentSegment(from: try imageSource(from: part))))
            case .toolCall:
                flushReasoning()
                flushContent()
                let json = toolCallInputJSON(part.input)
                let arguments: GeneratedContent
                do {
                    arguments = try GeneratedContent(json: json)
                } catch {
                    throw AfmSetupError.invalidToolInput(
                        "tool-call input for '\(part.toolName ?? "?")' is not valid JSON: \(json)"
                    )
                }
                toolCalls.append(
                    .init(
                        id: part.toolCallId ?? UUID().uuidString,
                        toolName: part.toolName ?? "",
                        arguments: arguments
                    )
                )
            case .toolResult:
                throw AfmSetupError.unsupportedContent(
                    "tool-result parts must be in a 'tool' role message"
                )
            }
        }

        flushReasoning()
        flushContent()
        flushToolCalls()
        return entries
    }

    // MARK: User content

    private static func contentSegments(_ parts: [AfmPart]) throws -> [Transcript.Segment] {
        try parts.map { part in
            switch part.type {
            case .text:
                return .text(.init(content: part.text ?? ""))
            case .file:
                return .attachment(attachmentSegment(from: try imageSource(from: part)))
            default:
                throw AfmSetupError.unsupportedContent(
                    "user messages may only contain text and file parts (got \(part.type.rawValue))"
                )
            }
        }
    }

    private static func promptFrom(parts: [AfmPart]) throws -> Prompt {
        let pieces = try parts.map { part -> PromptPiece in
            switch part.type {
            case .text:
                return PromptPiece(payload: .text(part.text ?? ""))
            case .file:
                return PromptPiece(payload: .image(try imageSource(from: part)))
            default:
                throw AfmSetupError.unsupportedContent(
                    "user messages may only contain text and file parts (got \(part.type.rawValue))"
                )
            }
        }
        guard !pieces.isEmpty else { return Prompt("") }
        return Prompt(pieces)
    }

    // MARK: Images

    enum ImageSource {
        case url(URL)
        case image(CIImage)
    }

    struct PromptPiece: PromptRepresentable {
        enum Payload {
            case text(String)
            case image(ImageSource)
        }

        var payload: Payload

        var promptRepresentation: Prompt { makePrompt() }

        private func makePrompt() -> Prompt {
            switch payload {
            case .text(let text):
                return Prompt(text)
            case .image(.url(let url)):
                return Prompt(Attachment(imageURL: url))
            case .image(.image(let image)):
                return Prompt(Attachment(image))
            }
        }
    }

    static func attachmentSegment(from source: ImageSource) -> Transcript.AttachmentSegment {
        let attachment: Transcript.ImageAttachment
        switch source {
        case .url(let url):
            attachment = Transcript.ImageAttachment(imageURL: url)
        case .image(let image):
            attachment = Transcript.ImageAttachment(image)
        }
        return Transcript.AttachmentSegment(content: .image(attachment))
    }

    static func imageSource(from part: AfmPart) throws -> ImageSource {
        guard let mediaType = part.mediaType, mediaType.lowercased().hasPrefix("image/") else {
            throw AfmSetupError.unsupportedContent(
                "only image/* file parts are supported (got \(part.mediaType ?? "no mediaType"))"
            )
        }
        guard let data = part.data, !data.isEmpty else {
            throw AfmSetupError.invalidImage("file part has no data")
        }

        if data.hasPrefix("data:") {
            guard
                let comma = data.firstIndex(of: ","),
                let bytes = Data(base64Encoded: String(data[data.index(after: comma)...])),
                let image = CIImage(data: bytes)
            else {
                throw AfmSetupError.invalidImage("could not decode data: URL image")
            }
            return .image(image)
        }

        if let url = URL(string: data),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            return .url(url)
        }

        guard let bytes = Data(base64Encoded: data), let image = CIImage(data: bytes) else {
            throw AfmSetupError.invalidImage("could not decode base64 image data")
        }
        return .image(image)
    }

    // MARK: Tool calls & results

    /// Normalizes an AI SDK tool-call `input` into a JSON string.
    static func toolCallInputJSON(_ input: JSONValue?) -> String {
        guard let input else { return "{}" }
        if case .string(let raw) = input {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return trimmed
            }
            return JSONValue.string(raw).jsonString()
        }
        return input.jsonString()
    }

    /// Normalizes an AI SDK tool-result `output` into transcript text.
    /// Accepts `{type: "text"|"json"|"error-text"|"error-json", value}` shapes
    /// or arbitrary JSON.
    static func toolOutputText(_ output: JSONValue?) -> String {
        guard let output else { return "" }
        if let object = output.objectValue,
           let type = object["type"]?.stringValue,
           let value = object["value"] {
            switch type {
            case "text", "error-text":
                return value.stringValue ?? value.jsonString()
            default:
                return value.jsonString()
            }
        }
        if case .string(let text) = output { return text }
        return output.jsonString()
    }
}
