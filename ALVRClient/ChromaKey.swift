//
//  ChromaKey.swift
//
// The chroma key the renderer applies: the client's own settings, or the one the streamer
// sends (ALVR's video.passthrough, RGB or HSV chroma key), as the standalone clients use it.
//
import Metal
import simd

struct ChromaKeyParams: Equatable {
    // Matches ALVRFunctionConstantChromaKeyMode in Shaders.metal
    enum Mode: UInt32 {
        case client = 0   // key color + blend distance range, from the client's settings
        case streamerRgb = 1
        case streamerHsv = 2
    }

    var enabled = false
    var mode = Mode.client

    // Mode .client
    var color = simd_float3(0.0, 1.0, 0.0)
    var lerpDistRange = simd_float2(0.005, 0.1)

    // Modes .streamerRgb/.streamerHsv: per channel (r,g,b or h,s,v), the four edges
    // (start max, start min, end min, end max) of the two smoothsteps whose maximum is
    // the opacity. Pixels between the start and end ramps are keyed out.
    var channel0 = simd_float4(repeating: 0)
    var channel1 = simd_float4(repeating: 0)
    var channel2 = simd_float4(repeating: 0)

    /// The client's own chroma key wins when it is switched on; otherwise the streamer's, if it
    /// asked for one and the client accepts it.
    /// Before visionOS 2 the key only works with the RealityKit renderer.
    static func current(_ settings: GlobalSettings, isRealityKit: Bool) -> ChromaKeyParams {
        var params = ChromaKeyParams()
        if #unavailable(visionOS 2.0), !isRealityKit {
            return params
        }
        if settings.chromaKeyEnabled {
            params.enabled = true
            params.color = simd_float3(settings.chromaKeyColorR, settings.chromaKeyColorG, settings.chromaKeyColorB)
            params.lerpDistRange = simd_float2(settings.chromaKeyDistRangeMin, settings.chromaKeyDistRangeMax)
            return params
        }
        if settings.chromaKeyFromStreamer, let passthrough = Settings.getAlvrSettings()?.video.passthrough {
            switch passthrough {
            case .rgbChromaKey(let rgb):
                params.enabled = true
                params.mode = .streamerRgb
                let thresh = rgb.distance_threshold / 255.0
                let up = 1.0 + rgb.feathering
                let down = 1.0 - rgb.feathering
                let range = thresh * simd_float4(-up, -down, down, up)
                params.channel0 = rgb.red / 255.0 + range
                params.channel1 = rgb.green / 255.0 + range
                params.channel2 = rgb.blue / 255.0 + range
            case .hsvChromaKey(let hsv):
                params.enabled = true
                params.mode = .streamerHsv
                let degToNorm: Float = 1.0 / 360.0
                params.channel0 = simd_float4(hsv.hue_start_max_deg, hsv.hue_start_min_deg, hsv.hue_end_min_deg, hsv.hue_end_max_deg) * degToNorm
                params.channel1 = simd_float4(hsv.saturation_start_max, hsv.saturation_start_min, hsv.saturation_end_min, hsv.saturation_end_max)
                params.channel2 = simd_float4(hsv.value_start_max, hsv.value_start_min, hsv.value_end_min, hsv.value_end_max)
            case .blend, .unsupported:
                break
            }
        }
        return params
    }

    func wantsRebuild(for settings: GlobalSettings, isRealityKit: Bool) -> Bool {
        return self != ChromaKeyParams.current(settings, isRealityKit: isRealityKit)
    }

    func setFunctionConstants(_ constants: MTLFunctionConstantValues) {
        var enabled = self.enabled
        var mode = self.mode.rawValue
        var colorLinear = NonlinearToLinearRGB(color)
        var lerpDistRange = self.lerpDistRange
        var channel0 = self.channel0
        var channel1 = self.channel1
        var channel2 = self.channel2
        constants.setConstantValue(&enabled, type: .bool, index: ALVRFunctionConstant.chromaKeyEnabled.rawValue)
        constants.setConstantValue(&mode, type: .uint, index: ALVRFunctionConstant.chromaKeyMode.rawValue)
        constants.setConstantValue(&colorLinear, type: .float3, index: ALVRFunctionConstant.chromaKeyColor.rawValue)
        constants.setConstantValue(&lerpDistRange, type: .float2, index: ALVRFunctionConstant.chromaKeyLerpDistRange.rawValue)
        constants.setConstantValue(&channel0, type: .float4, index: ALVRFunctionConstant.chromaKeyChannel0.rawValue)
        constants.setConstantValue(&channel1, type: .float4, index: ALVRFunctionConstant.chromaKeyChannel1.rawValue)
        constants.setConstantValue(&channel2, type: .float4, index: ALVRFunctionConstant.chromaKeyChannel2.rawValue)
    }
}
