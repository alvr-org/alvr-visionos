//
//  FFR.swift
//
// Foveation vars as read from the Streamer's JSON config.
//

import Foundation
import Metal

struct FoveationSettings: Codable {
    var centerSizeX: Float = 0
    var centerSizeY: Float = 0
    var centerShiftX: Float = 0
    var centerShiftY: Float = 0
    var edgeRatioX: Float = 0
    var edgeRatioY: Float = 0

    enum CodingKeys: String, CodingKey {
        case centerSizeX = "center_size_x"
        case centerSizeY = "center_size_y"
        case centerShiftX = "center_shift_x"
        case centerShiftY = "center_shift_y"
        case edgeRatioX = "edge_ratio_x"
        case edgeRatioY = "edge_ratio_y"
    }
}

struct FoveationVars {
    let enabled: Bool
    
    let targetEyeWidth: UInt32
    let targetEyeHeight: UInt32
    let optimizedEyeWidth: UInt32
    let optimizedEyeHeight: UInt32

    let eyeWidthRatio: Float
    let eyeHeightRatio: Float

    let centerSizeX: Float
    let centerSizeY: Float
    let centerShiftX: Float
    let centerShiftY: Float
    let edgeRatioX: Float
    let edgeRatioY: Float
}

struct FFR {
    private init() {}
    
    public static func calculateFoveationVars(alvrEvent: StreamingStarted_Body, foveationSettings: FoveationSettings?) -> FoveationVars {
        guard let settings = foveationSettings else {
            return FoveationVars(
                enabled: false,
                targetEyeWidth: 0,
                targetEyeHeight: 0,
                optimizedEyeWidth: 0,
                optimizedEyeHeight: 0,
                eyeWidthRatio: 0,
                eyeHeightRatio: 0,
                centerSizeX: 0,
                centerSizeY: 0,
                centerShiftX: 0,
                centerShiftY: 0,
                edgeRatioX: 0,
                edgeRatioY: 0
            )
        }

        let targetEyeWidth = Float(alvrEvent.view_width)
        let targetEyeHeight = Float(alvrEvent.view_height)
        
        let centerSizeX = settings.centerSizeX
        let centerSizeY = settings.centerSizeY
        let centerShiftX = settings.centerShiftX
        let centerShiftY = settings.centerShiftY
        let edgeRatioX = settings.edgeRatioX
        let edgeRatioY = settings.edgeRatioY

        let edgeSizeX = targetEyeWidth - centerSizeX * targetEyeWidth
        let edgeSizeY = targetEyeHeight - centerSizeY * targetEyeHeight

        let centerSizeXAligned = 1 - ceil(edgeSizeX / (edgeRatioX * 2)) * (edgeRatioX * 2) / targetEyeWidth
        let centerSizeYAligned = 1 - ceil(edgeSizeY / (edgeRatioY * 2)) * (edgeRatioY * 2) / targetEyeHeight

        let edgeSizeXAligned = targetEyeWidth - centerSizeXAligned * targetEyeWidth
        let edgeSizeYAligned = targetEyeHeight - centerSizeYAligned * targetEyeHeight

        let centerShiftXAligned = ceil(centerShiftX * edgeSizeXAligned / (edgeRatioX * 2)) * (edgeRatioX * 2) / edgeSizeXAligned
        let centerShiftYAligned = ceil(centerShiftY * edgeSizeYAligned / (edgeRatioY * 2)) * (edgeRatioY * 2) / edgeSizeYAligned

        let foveationScaleX = (centerSizeXAligned + (1 - centerSizeXAligned) / edgeRatioX)
        let foveationScaleY = (centerSizeYAligned + (1 - centerSizeYAligned) / edgeRatioY)

        let optimizedEyeWidth = foveationScaleX * targetEyeWidth
        let optimizedEyeHeight = foveationScaleY * targetEyeHeight

        // round the frame dimensions to a number of pixel multiple of 32 for the encoder
        let optimizedEyeWidthAligned = UInt32(ceil(optimizedEyeWidth / 32) * 32)
        let optimizedEyeHeightAligned = UInt32(ceil(optimizedEyeHeight / 32) * 32)
        
        let eyeWidthRatioAligned = optimizedEyeWidth / Float(optimizedEyeWidthAligned)
        let eyeHeightRatioAligned = optimizedEyeHeight / Float(optimizedEyeHeightAligned)
        
        return FoveationVars(
            enabled: true,
            targetEyeWidth: alvrEvent.view_width,
            targetEyeHeight: alvrEvent.view_height,
            optimizedEyeWidth: optimizedEyeWidthAligned,
            optimizedEyeHeight: optimizedEyeHeightAligned,
            eyeWidthRatio: eyeWidthRatioAligned,
            eyeHeightRatio: eyeHeightRatioAligned,
            centerSizeX: centerSizeXAligned,
            centerSizeY: centerSizeYAligned,
            centerShiftX: centerShiftXAligned,
            centerShiftY: centerShiftYAligned,
            edgeRatioX: edgeRatioX,
            edgeRatioY: edgeRatioY
        )
        
    }
    
    public static func makeFunctionConstants(_ vars: FoveationVars) -> MTLFunctionConstantValues {
        let constants = MTLFunctionConstantValues()
        var boolValue = vars.enabled
        constants.setConstantValue(&boolValue, type: .bool, index: ALVRFunctionConstant.ffrEnabled.rawValue)
        
        var float2Value: [Float32] = [vars.eyeWidthRatio, vars.eyeHeightRatio]
        constants.setConstantValue(&float2Value, type: .float2, index: ALVRFunctionConstant.ffrCommonShaderEyeSizeRatio.rawValue)
        
        float2Value = [vars.centerSizeX, vars.centerSizeY]
        constants.setConstantValue(&float2Value, type: .float2, index: ALVRFunctionConstant.ffrCommonShaderCenterSize.rawValue)
        
        float2Value = [vars.centerShiftX, vars.centerShiftY]
        constants.setConstantValue(&float2Value, type: .float2, index: ALVRFunctionConstant.ffrCommonShaderCenterShift.rawValue)
        
        float2Value = [vars.edgeRatioX, vars.edgeRatioY]
        constants.setConstantValue(&float2Value, type: .float2, index: ALVRFunctionConstant.ffrCommonShaderEdgeRatio.rawValue)
        
        return constants
    }
}
