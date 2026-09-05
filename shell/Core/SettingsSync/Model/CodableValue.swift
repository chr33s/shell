//
//  CodableValue.swift
//  shell
//
//  Type-erasing wrapper for the value types a registered setting can hold.
//  Used by the settings registry and by CloudKit settings sync.
//

import Foundation

nonisolated enum CodableValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case stringArray([String])

    enum CodingKeys: String, CodingKey {
        case type, value
    }

    enum ValueType: String, Codable {
        case string, int, double, bool, data, stringArray
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .data:
            self = .data(try container.decode(Data.self, forKey: .value))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .data(let v):
            try container.encode(ValueType.data, forKey: .type)
            try container.encode(v, forKey: .value)
        case .stringArray(let v):
            try container.encode(ValueType.stringArray, forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let v): v
        case .int(let v): v
        case .double(let v): v
        case .bool(let v): v
        case .data(let v): v
        case .stringArray(let v): v
        }
    }

    init?(from value: Any) {
        switch value {
        case let v as String:
            self = .string(v)
        case let v as Int:
            self = .int(v)
        case let v as Double:
            self = .double(v)
        case let v as Bool:
            self = .bool(v)
        case let v as Data:
            self = .data(v)
        case let v as [String]:
            self = .stringArray(v)
        default:
            return nil
        }
    }
}
