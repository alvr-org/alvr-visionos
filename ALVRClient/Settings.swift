import Foundation

enum Switch<C>: Codable where C: Codable {
    case disabled
    case content(C)

    enum RawJsonKeys: String, CodingKey {
        case Enabled
    }

    init(from decoder: Decoder) throws {
        let disabledValueContainer = try decoder.singleValueContainer()
        let container = try? decoder.container(keyedBy: RawJsonKeys.self)

        if let value = try? disabledValueContainer.decode(String.self) {
            if value == "Disabled" {
                self = .disabled
            } else {
                throw ConfigurationError.badJson
            }
        } else if let value = try? container?.decode(C.self, forKey: .Enabled) {
            self = .content(value)
        } else {
            throw ConfigurationError.badJson
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch (self) {
        case .disabled:
            try container.encode("Disabled")
        case .content(let value):
            try container.encode(value)
        }
    }
}

struct VideoConfig: Codable {
    let foveatedEncoding: Switch<FoveationSettings>

    enum CodingKeys: String, CodingKey {
        case foveatedEncoding = "foveated_encoding"
    }
}

struct Settings: Codable {
    let video: VideoConfig
}

func getAlvrSettings() -> Settings? {
    let len = alvr_get_settings_json(nil)
    if len == 0 {
        return nil
    }
    let settingsJsonBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: Int(len))
    defer { settingsJsonBuffer.deallocate() }

    alvr_get_settings_json(settingsJsonBuffer.baseAddress)
    let settingsData = Data(bytesNoCopy: settingsJsonBuffer.baseAddress!, count: Int(len) - 1, deallocator: .none)

    return try! JSONDecoder().decode(Settings.self, from: settingsData)
}
