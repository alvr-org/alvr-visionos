//
//  Settings.swift
//
// ALVR server-side settings decoded from JSON.
//
import Foundation

enum SettingsError: Error {
    case badJson
}

struct SettingsCodables {
    struct EncoderConfig: Codable {
        var encodingGamma: Float = 1.0
        var enableHdr: Bool = false

        enum CodingKeys: String, CodingKey {
            case encodingGamma = "encoding_gamma"
            case enableHdr = "enable_hdr"
        }
        var encoding_gamma: Float = 1.0
        var enable_hdr: Bool = false
    }

    struct VideoConfig: Codable {
        @OptionSwitch var foveated_encoding: FoveationSettings?
        let encoder_config: EncoderConfig
    }
    
    //
    // Headset
    //
    struct HandSkeletonConfig: Codable {
        @DefaultFalse var steamvr_input_2_0: Bool
    }
    
    struct ControllersConfig: Codable {
        @DefaultTrue var tracked: Bool
        //@DefaultTrue var enable_skeleton: Bool
        @DefaultFalse var multimodal_tracking: Bool
        @DefaultEmptyArray var left_controller_position_offset: [Float]
        @DefaultEmptyArray var left_controller_rotation_offset: [Float]
        @DefaultEmptyArray var left_hand_tracking_position_offset: [Float]
        @DefaultEmptyArray var left_hand_tracking_rotation_offset: [Float]
        @OptionSwitch var hand_skeleton: HandSkeletonConfig?
        @DefaultEmptyString var emulation_mode: String
    }
    
    struct HeadsetConfig: Codable {
        @OptionSwitch var controllers: ControllersConfig?
    }

    struct Settings: Codable {
        let video: VideoConfig
        let headset: HeadsetConfig
    }
}

struct Settings {
    private init() {}
    
    static var _cached: SettingsCodables.Settings?

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
        if Settings._cached != nil {
            return Settings._cached
        }

        let val = parseSettingsJsonCString(getJson: alvr_get_settings_json, type: SettingsCodables.Settings.self)
        Settings._cached = val
        return val
    }
    
    public static func clearSettingsCache() {
        Settings._cached = nil
    }
}
