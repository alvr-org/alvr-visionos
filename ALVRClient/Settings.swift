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
    //
    // Passthrough (video.passthrough). The streamer's chroma key settings, same meaning as on the
    // standalone clients. Decoding never throws: a variant or field this client doesn't know
    // becomes .unsupported rather than invalidating the whole settings blob.
    //
    struct RgbChromaKeyConfig: Codable {
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0
        var distance_threshold: Float = 1
        var feathering: Float = 0.01
    }

    struct HsvChromaKeyConfig: Codable {
        var hue_start_max_deg: Float = 0
        var hue_start_min_deg: Float = 0
        var hue_end_min_deg: Float = 0
        var hue_end_max_deg: Float = 0
        var saturation_start_max: Float = 0
        var saturation_start_min: Float = 0
        var saturation_end_min: Float = 0
        var saturation_end_max: Float = 0
        var value_start_max: Float = 0
        var value_start_min: Float = 0
        var value_end_min: Float = 0
        var value_end_max: Float = 0
    }

    enum PassthroughMode: Codable {
        case blend // alpha blending has no counterpart here, treated as no keying
        case rgbChromaKey(RgbChromaKeyConfig)
        case hsvChromaKey(HsvChromaKeyConfig)
        case unsupported

        enum CodingKeys: String, CodingKey {
            case Blend, RgbChromaKey, HsvChromaKey
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                self = .unsupported
                return
            }
            if let rgb = try? container.decode(RgbChromaKeyConfig.self, forKey: .RgbChromaKey) {
                self = .rgbChromaKey(rgb)
            } else if let hsv = try? container.decode(HsvChromaKeyConfig.self, forKey: .HsvChromaKey) {
                self = .hsvChromaKey(hsv)
            } else if container.contains(.Blend) {
                self = .blend
            } else {
                self = .unsupported
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .rgbChromaKey(let rgb): try container.encode(rgb, forKey: .RgbChromaKey)
            case .hsvChromaKey(let hsv): try container.encode(hsv, forKey: .HsvChromaKey)
            case .blend, .unsupported: break
            }
        }
    }

    struct VideoConfig: Codable {
        @OptionSwitch var foveated_encoding: FoveationSettings?
        @OptionSwitch var passthrough: PassthroughMode?
    }
    
    //
    // Headset
    //
    struct HandSkeletonConfig: Codable {
        @DefaultFalse var steamvr_input_2_0: Bool
    }
    
    struct HandTrackingInteraction: Codable {
        @DefaultFalse var only_touch: Bool
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
        @OptionSwitch var hand_tracking_interaction: HandTrackingInteraction?
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
