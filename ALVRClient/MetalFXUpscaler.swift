//
//  MetalFXUpscaler.swift
//
//  Created by @xuhao1 on 2024/3/16.
//

import Metal
#if !targetEnvironment(simulator)
import MetalFX
#endif
import CoreGraphics

class MetalUpscaler {
    private let device: MTLDevice
    
#if !targetEnvironment(simulator)
    var mfxSpatialScaler: MTLFXSpatialScaler!
#endif
    var outputTexture: MTLTexture!
    var scaling: Float32 = 1.0
    var is_inited: Bool = false
    
    init?(device: MTLDevice, scaling: Float32 = 1.5) {
        self.device = device
        self.scaling = scaling
    }
    
    func initUpscalerByTexture(inputTexture: MTLTexture) {
        let inputWidth = inputTexture.width
        let inputHeight = inputTexture.height
        let pixelFormat = inputTexture.pixelFormat
        self.setupSpatialScaler(inputWidth: inputWidth, inputHeight: inputHeight, scaling: scaling, pixelFormat: pixelFormat)
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2D
        textureDescriptor.pixelFormat = pixelFormat
        textureDescriptor.width = Int(Float(inputWidth)*scaling)
        textureDescriptor.height = Int(Float(inputHeight)*scaling)
        textureDescriptor.storageMode = .private

        // Optionally, set the usage of the texture. For rendering, you'll likely need shader read and render target capabilities
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        self.outputTexture = device.makeTexture(descriptor: textureDescriptor)
        self.is_inited = true
        
    }
    
    
    func setupSpatialScaler(inputWidth:Int, inputHeight: Int, scaling: Float32, pixelFormat: MTLPixelFormat) {
#if !targetEnvironment(simulator)
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputWidth
        desc.inputHeight = inputHeight
        desc.outputWidth = Int(Float(inputWidth)*scaling)
        desc.outputHeight = Int(Float(inputHeight)*scaling)
        desc.colorTextureFormat = pixelFormat
        desc.outputTextureFormat = pixelFormat
        desc.colorProcessingMode = .perceptual
        
        guard let spatialScaler = desc.makeSpatialScaler(device: device) else {
            print("The spatial scaler effect is not usable!")
            return
        }
        print("Init MetalFX,Spatial upscaler from [\(inputWidth)x\(inputHeight)] to [\(Int(Float(inputWidth)*scaling))x\(Int(Float(inputHeight)*scaling))] scaling \(scaling) format \(pixelFormat)")
        mfxSpatialScaler = spatialScaler
#endif
    }
    
    func addUpscaleCommand(inputTexture: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture! {
        if (!is_inited)
        {
            initUpscalerByTexture(inputTexture: inputTexture)
        }
#if !targetEnvironment(simulator)
        if let spatialScaler = mfxSpatialScaler {
            spatialScaler.colorTexture = inputTexture
            spatialScaler.outputTexture = self.outputTexture
            spatialScaler.encode(commandBuffer: commandBuffer)
            return self.outputTexture
        }
#else
        return inputTexture
#endif
        return nil
    }
}

