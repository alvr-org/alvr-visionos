//
//  FFR.swift
//  ALVRClient
//
//  Created by Shadowfacts on 2/7/24.
//

import Foundation
import Metal

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
    
    public static func calculateFoveationVars(_ data: StreamingStarted_Body) -> FoveationVars {
        guard data.enable_foveation else {
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
        
        let targetEyeWidth = Float(data.view_width)
        let targetEyeHeight = Float(data.view_height)
        
        let centerSizeX = data.foveation_center_size_x
        let centerSizeY = data.foveation_center_size_y
        let centerShiftX = data.foveation_center_shift_x
        let centerShiftY = data.foveation_center_shift_y
        let edgeRatioX = data.foveation_edge_ratio_x
        let edgeRatioY = data.foveation_edge_ratio_y

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
            enabled: data.enable_foveation,
            targetEyeWidth: data.view_width,
            targetEyeHeight: data.view_height,
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
