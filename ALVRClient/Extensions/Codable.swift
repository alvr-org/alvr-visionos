//
//  Extensions/Codable.swift
//

@propertyWrapper
struct DefaultEmptyArray<T:Codable> {
    var wrappedValue: [T] = []
}

//codable extension to encode/decode the wrapped value
extension DefaultEmptyArray: Codable {
    
    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode([T].self)
    }
}

@propertyWrapper
struct DefaultEmptyString : Codable {
    var wrappedValue = ""
}

//codable extension to encode/decode the wrapped value
extension DefaultEmptyString {
    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode(String.self)
    }
}

@propertyWrapper
struct DefaultFalse : Codable {
    var wrappedValue = false
}

//codable extension to encode/decode the wrapped value
extension DefaultFalse {
    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode(Bool.self)
    }
}

@propertyWrapper
struct DefaultTrue : Codable {
    var wrappedValue = true
}

//codable extension to encode/decode the wrapped value
extension DefaultTrue {
    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode(Bool.self)
    }
}

@propertyWrapper
struct OptionSwitch<C: Codable> {
    var wrappedValue: C? = nil
}

//codable extension to encode/decode the wrapped value
extension OptionSwitch: Codable {
    enum RawJsonKeys: String, CodingKey {
        case Enabled
    }
    
    init(from decoder: Decoder) throws {
        let disabledValueContainer = try decoder.singleValueContainer()
        let container = try? decoder.container(keyedBy: RawJsonKeys.self)

        if let value = try? disabledValueContainer.decode(String.self) {
            if value == "Disabled" {
                self.wrappedValue = nil
            } else {
                throw SettingsError.badJson
            }
        } else if let value = try? container?.decode(C.self, forKey: .Enabled) {
            self.wrappedValue = value
        } else {
            throw SettingsError.badJson
        }
    }

    func encode(to encoder: Encoder) throws {
        if self.wrappedValue == nil {
            var container = encoder.singleValueContainer()
            try container.encode("Disabled")
        }
        else {
            var container = encoder.container(keyedBy: RawJsonKeys.self)
            try container.encode(self.wrappedValue, forKey: .Enabled)
        }
    }
}

extension KeyedDecodingContainer {
    func decode<T:Decodable>(_ type: DefaultEmptyArray<T>.Type,
                forKey key: Key) throws -> DefaultEmptyArray<T> {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
    
    func decode(_ type: DefaultEmptyString.Type,
                forKey key: Key) throws -> DefaultEmptyString {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
    
    func decode(_ type: DefaultFalse.Type,
                forKey key: Key) throws -> DefaultFalse {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
    
    func decode(_ type: DefaultTrue.Type,
                forKey key: Key) throws -> DefaultTrue {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
    
    func decode<T:Decodable>(_ type: OptionSwitch<T>.Type,
                forKey key: Key) throws -> OptionSwitch<T> {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}
