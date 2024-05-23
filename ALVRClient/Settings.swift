import Foundation

enum SettingsError: Error {
    case badJson
}

struct SettingsCodables {
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
                    throw SettingsError.badJson
                }
            } else if let value = try? container?.decode(C.self, forKey: .Enabled) {
                self = .content(value)
            } else {
                throw SettingsError.badJson
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
    
    struct EncoderConfig: Codable {
        var encodingGamma: Float = 1.0
        var enableHdr: Bool = false

        enum CodingKeys: String, CodingKey {
            case encodingGamma = "encoding_gamma"
            case enableHdr = "enable_hdr"
        }
    }

    struct VideoConfig: Codable {
        let foveatedEncoding: Switch<FoveationSettings>
        let encoderConfig: EncoderConfig

        enum CodingKeys: String, CodingKey {
            case foveatedEncoding = "foveated_encoding"
            case encoderConfig = "encoder_config"
        }
    }

    struct Settings: Codable {
        let video: VideoConfig
    }
}

struct Settings {
    private init() {}

    private static func parseSettingsJsonCString<T: Decodable>(getJson: (UnsafeMutablePointer<CChar>?) -> UInt64, type: T.Type) -> T? {
        let len = getJson(nil)
        if len == 0 {
            return nil
        }

        let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: Int(len))
        defer { buffer.deallocate() }

        _ = getJson(buffer.baseAddress)
        let data = Data(bytesNoCopy: buffer.baseAddress!, count: Int(len) - 1, deallocator: .none)
        
        // Helper to see/debug JSON
        /*if let utf8String = String(bytes: data, encoding: .utf8) {
            print(utf8String.trimmingCharacters(in: ["\0"]))
        }*/
        
        do {
            return try JSONDecoder().decode(T.self, from: data)
        }
        catch {
            return nil
        }
    }

    public static func getAlvrSettings() -> SettingsCodables.Settings? {
        return parseSettingsJsonCString(getJson: alvr_get_settings_json, type: SettingsCodables.Settings.self)
    }
}
