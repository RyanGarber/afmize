import Foundation
import FoundationModels

/// Converts JSON Schema (as used by AI SDK function tools) into
/// FoundationModels `GenerationSchema` via `DynamicGenerationSchema`.
enum SchemaConversion {
    static func generationSchema(name: String, jsonSchema: JSONValue?) throws -> GenerationSchema {
        let root = dynamicSchema(jsonSchema ?? .object([:]), name: name)
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func dynamicSchema(_ schema: JSONValue, name: String) -> DynamicGenerationSchema {
        guard case .object(let object) = schema else {
            // `true` or other non-object schemas: accept freeform content.
            return DynamicGenerationSchema(type: GeneratedContent.self)
        }

        let description = object["description"]?.stringValue

        if let choices = (object["anyOf"] ?? object["oneOf"])?.arrayValue, !choices.isEmpty {
            let subschemas = choices.enumerated().map { index, choice in
                dynamicSchema(choice, name: "\(name)Option\(index)")
            }
            return DynamicGenerationSchema(name: name, description: description, anyOf: subschemas)
        }

        let typeName = object["type"]?.stringValue
            ?? (object["properties"] != nil ? "object" : nil)

        switch typeName {
        case "object":
            var required: Set<String> = []
            if let names = object["required"]?.arrayValue {
                required = Set(names.compactMap(\.stringValue))
            }
            var properties: [DynamicGenerationSchema.Property] = []
            if let propertyMap = object["properties"]?.objectValue {
                // Dictionary decoding loses author order; sort for determinism.
                for (key, value) in propertyMap.sorted(by: { $0.key < $1.key }) {
                    properties.append(
                        DynamicGenerationSchema.Property(
                            name: key,
                            description: value.objectValue?["description"]?.stringValue,
                            schema: dynamicSchema(value, name: "\(name).\(key)"),
                            isOptional: !required.contains(key)
                        )
                    )
                }
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)

        case "string":
            if let values = object["enum"]?.arrayValue {
                let choices = values.map { $0.stringValue ?? $0.jsonString() }
                if !choices.isEmpty {
                    return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
                }
            }
            return DynamicGenerationSchema(type: String.self)

        case "integer":
            var guides: [GenerationGuide<Int>] = []
            if let minimum = object["minimum"]?.intValue { guides.append(.minimum(minimum)) }
            if let maximum = object["maximum"]?.intValue { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)

        case "number":
            var guides: [GenerationGuide<Double>] = []
            if let minimum = object["minimum"]?.doubleValue { guides.append(.minimum(minimum)) }
            if let maximum = object["maximum"]?.doubleValue { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)

        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)

        case "array":
            let itemSchema = dynamicSchema(object["items"] ?? .object([:]), name: "\(name).item")
            return DynamicGenerationSchema(
                arrayOf: itemSchema,
                minimumElements: object["minItems"]?.intValue,
                maximumElements: object["maxItems"]?.intValue
            )

        case "null":
            return .null

        default:
            return DynamicGenerationSchema(type: GeneratedContent.self)
        }
    }
}
