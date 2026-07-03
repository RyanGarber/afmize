import Foundation

// MARK: - JSONValue

/// A Codable representation of an arbitrary JSON value. Used for tool input
/// schemas, tool-call inputs, and tool-result outputs.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value == value.rounded() else { return nil }
        return Int(value)
    }

    /// Serializes this value to a compact JSON string.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Request

public enum AfmModelChoice: String, Codable, Sendable {
    case onDevice = "on-device"
    case privateCloudCompute = "private-cloud-compute"
}

public enum AfmRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum AfmPartType: String, Codable, Sendable {
    case text
    case file
    case reasoning
    case toolCall = "tool-call"
    case toolResult = "tool-result"
}

public enum AfmToolChoice: String, Codable, Sendable {
    case auto
    case required
    case none
}

/// One content part of a message, mirroring AI SDK `LanguageModelV3` parts.
public struct AfmPart: Codable, Sendable {
    public var type: AfmPartType
    /// Text content for `text` and `reasoning` parts.
    public var text: String?
    /// IANA media type for `file` parts (only `image/*` is supported).
    public var mediaType: String?
    /// File content: base64 data, a `data:` URL, or a `file:`/`http(s):` URL.
    public var data: String?
    public var filename: String?
    /// Tool call/result correlation id.
    public var toolCallId: String?
    public var toolName: String?
    /// Tool-call input (JSON object, or a JSON-encoded string).
    public var input: JSONValue?
    /// Tool-result output. Accepts AI SDK `{type, value}` shapes or plain JSON.
    public var output: JSONValue?

    public init(
        type: AfmPartType,
        text: String? = nil,
        mediaType: String? = nil,
        data: String? = nil,
        filename: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        input: JSONValue? = nil,
        output: JSONValue? = nil
    ) {
        self.type = type
        self.text = text
        self.mediaType = mediaType
        self.data = data
        self.filename = filename
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
        self.output = output
    }
}

public struct AfmMessage: Codable, Sendable {
    public var role: AfmRole
    public var parts: [AfmPart]

    public init(role: AfmRole, parts: [AfmPart]) {
        self.role = role
        self.parts = parts
    }
}

/// A function tool definition, mirroring AI SDK `LanguageModelV3FunctionTool`.
public struct AfmToolDefinition: Codable, Sendable {
    public var name: String
    public var description: String?
    /// JSON Schema for the tool input.
    public var inputSchema: JSONValue?

    public init(name: String, description: String? = nil, inputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct AfmRequest: Codable, Sendable {
    public var model: AfmModelChoice
    public var messages: [AfmMessage]
    public var tools: [AfmToolDefinition]?
    /// "auto" | "required" | "none". Defaults to "auto" when tools are present.
    public var toolChoice: AfmToolChoice?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    /// "light" | "moderate" | "deep", or any other string as a custom level.
    public var reasoningLevel: String?

    public init(
        model: AfmModelChoice,
        messages: [AfmMessage],
        tools: [AfmToolDefinition]? = nil,
        toolChoice: AfmToolChoice? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        reasoningLevel: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reasoningLevel = reasoningLevel
    }
}

// MARK: - Events

public struct AfmUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var totalTokens: Int

    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        totalTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
    }
}

/// A single stream event, mirroring AI SDK `LanguageModelV3StreamPart`.
///
/// Event types, in emission order:
/// - `stream-start`: always first.
/// - `text-delta` / `text-replace`: response text (`id` identifies the block).
/// - `reasoning-delta` / `reasoning-replace`: reasoning text per reasoning block.
/// - `file`: a file emitted by the model (`mediaType` + base64 `data` or URL).
/// - `tool-call`: a tool call; `input` is a JSON-encoded string. All tool calls
///   of the turn are emitted before `finish` with reason `tool-calls`.
/// - `error`: a fatal error (`code`, `message`), followed by `finish`.
/// - `finish`: always last, exactly once. `finishReason` is one of
///   `stop` | `tool-calls` | `error` | `other`; includes `usage` when known.
public struct AfmEvent: Codable, Sendable {
    public var type: String
    public var id: String?
    public var delta: String?
    public var text: String?
    public var mediaType: String?
    public var data: String?
    public var toolCallId: String?
    public var toolName: String?
    public var input: String?
    public var code: String?
    public var message: String?
    public var finishReason: String?
    public var usage: AfmUsage?

    public static func streamStart() -> AfmEvent {
        AfmEvent(type: "stream-start")
    }

    public static func textDelta(id: String, delta: String) -> AfmEvent {
        AfmEvent(type: "text-delta", id: id, delta: delta)
    }

    public static func textReplace(id: String, text: String) -> AfmEvent {
        AfmEvent(type: "text-replace", id: id, text: text)
    }

    public static func reasoningDelta(id: String, delta: String) -> AfmEvent {
        AfmEvent(type: "reasoning-delta", id: id, delta: delta)
    }

    public static func reasoningReplace(id: String, text: String) -> AfmEvent {
        AfmEvent(type: "reasoning-replace", id: id, text: text)
    }

    public static func file(mediaType: String, data: String) -> AfmEvent {
        AfmEvent(type: "file", mediaType: mediaType, data: data)
    }

    public static func toolCall(id: String, name: String, input: String) -> AfmEvent {
        AfmEvent(type: "tool-call", toolCallId: id, toolName: name, input: input)
    }

    public static func error(code: String, message: String) -> AfmEvent {
        AfmEvent(type: "error", code: code, message: message)
    }

    public static func finish(reason: String, usage: AfmUsage?) -> AfmEvent {
        AfmEvent(type: "finish", finishReason: reason, usage: usage)
    }

    init(
        type: String,
        id: String? = nil,
        delta: String? = nil,
        text: String? = nil,
        mediaType: String? = nil,
        data: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        input: String? = nil,
        code: String? = nil,
        message: String? = nil,
        finishReason: String? = nil,
        usage: AfmUsage? = nil
    ) {
        self.type = type
        self.id = id
        self.delta = delta
        self.text = text
        self.mediaType = mediaType
        self.data = data
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
        self.code = code
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
    }

    /// Serializes this event to a compact JSON string.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return #"{"type":"error","code":"encoding-failure","message":"failed to encode event"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
