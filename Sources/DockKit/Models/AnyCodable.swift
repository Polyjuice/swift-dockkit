import Foundation

/// Type-erased Codable wrapper for heterogeneous JSON values
/// Used for the cargo field in TabLayoutState to allow arbitrary JSON content
public struct AnyCodable: Codable, Equatable, Hashable, Sendable {
    private let storage: Storage

    // MARK: - Storage

    private enum Storage: Equatable, Hashable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
    }

    // MARK: - Public Value Access

    /// The underlying value
    public var value: Any {
        switch storage {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.value }
        case .dictionary(let v): return v.mapValues { $0.value }
        }
    }

    // MARK: - Convenience Accessors

    public var isNull: Bool {
        if case .null = storage { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let v) = storage { return v }
        return nil
    }

    public var intValue: Int? {
        if case .int(let v) = storage { return v }
        return nil
    }

    public var doubleValue: Double? {
        switch storage {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let v) = storage { return v }
        return nil
    }

    public var arrayValue: [AnyCodable]? {
        if case .array(let v) = storage { return v }
        return nil
    }

    public var dictionaryValue: [String: AnyCodable]? {
        if case .dictionary(let v) = storage { return v }
        return nil
    }

    /// Access nested values by key (for dictionaries)
    public subscript(key: String) -> AnyCodable? {
        dictionaryValue?[key]
    }

    /// Access nested values by index (for arrays)
    public subscript(index: Int) -> AnyCodable? {
        guard let arr = arrayValue, index >= 0, index < arr.count else { return nil }
        return arr[index]
    }

    // MARK: - Initialization

    public init(_ value: Any) {
        switch value {
        case is NSNull:
            storage = .null
        case let v as Bool:
            storage = .bool(v)
        case let v as Int:
            storage = .int(v)
        case let v as Double:
            storage = .double(v)
        case let v as String:
            storage = .string(v)
        case let v as [Any]:
            storage = .array(v.map { AnyCodable($0) })
        case let v as [String: Any]:
            storage = .dictionary(v.mapValues { AnyCodable($0) })
        case let v as AnyCodable:
            storage = v.storage
        default:
            // Fallback for unknown types - try to describe as string
            storage = .string(String(describing: value))
        }
    }

    /// Create a null value
    public static var null: AnyCodable {
        AnyCodable(NSNull())
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            storage = .null
        } else if let bool = try? container.decode(Bool.self) {
            storage = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            storage = .int(int)
        } else if let double = try? container.decode(Double.self) {
            storage = .double(double)
        } else if let string = try? container.decode(String.self) {
            storage = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            storage = .array(array)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            storage = .dictionary(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch storage {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .dictionary(let v):
            try container.encode(v)
        }
    }
}

// MARK: - ExpressibleBy Literals

extension AnyCodable: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        storage = .null
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        storage = .bool(value)
    }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        storage = .int(value)
    }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        storage = .double(value)
    }
}

extension AnyCodable: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        storage = .string(value)
    }
}

extension AnyCodable: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyCodable...) {
        storage = .array(elements)
    }
}

extension AnyCodable: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyCodable)...) {
        storage = .dictionary(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - CustomStringConvertible

extension AnyCodable: CustomStringConvertible {
    public var description: String {
        switch storage {
        case .null: return "null"
        case .bool(let v): return v.description
        case .int(let v): return v.description
        case .double(let v): return v.description
        case .string(let v): return "\"\(v)\""
        case .array(let v): return v.description
        case .dictionary(let v): return v.description
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension AnyCodable: CustomDebugStringConvertible {
    public var debugDescription: String {
        "AnyCodable(\(description))"
    }
}
