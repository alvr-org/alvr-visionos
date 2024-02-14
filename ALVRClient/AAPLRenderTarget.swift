/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The class to create the render textures and render pass descriptors for the renderer.
*/

import Metal
import MetalKit

class AAPLRenderTarget {
    let device: MTLDevice
    var windowSize: MTLSize = MTLSize(width: 0, height: 0, depth: 0)
    var renderSize: MTLSize = MTLSize(width: 0, height: 0, depth: 0)
    var currentFrameColor: MTLTexture!
    var currentFrameDepth: MTLTexture!
    var currentFrameMotion: MTLTexture!
    var currentFrameUpscaledColor: MTLTexture!
    var currentFrameAntialiasedColor: MTLTexture!
    var makeMotionVectors: Bool = false
    var aspectRatio: Float = 1
    public var renderScale: Float = 0.5

    init(mtlDevice: MTLDevice) {
        device = mtlDevice
    }
    
    func renderOrWindowSizeIsInvalid() -> Bool {
        if windowSize.width == 0 || windowSize.width == 0 {
            return true
        }
        if renderSize.width == 0 || renderSize.height == 0 {
            return true
        }
        return false
    }
    
    func simdRenderSize() -> simd_float2 {
        return simd_float2(Float(renderSize.width), Float(renderSize.height))
    }
    
    func simdWindowSize() -> simd_float2 {
        return simd_float2(Float(windowSize.width), Float(windowSize.height))
    }
    
    func renderSizeX() -> Float {
        return Float(renderSize.width)
    }

    func renderSizeY() -> Float {
        return Float(renderSize.height)
    }
    
    func createAntialiasedColorTexture() {
        // Ensure the render size is valid.
        if renderOrWindowSizeIsInvalid() {
            return
        }
        
        // Create a texture for TAA to store the output.
        let desc = MTLTextureDescriptor()
        desc.width = renderSize.width
        desc.height = renderSize.height
        desc.usage = [ .renderTarget, .shaderRead, .shaderWrite ]
        desc.pixelFormat = .bgra8Unorm_srgb
        currentFrameAntialiasedColor = device.makeTexture(descriptor: desc)!
    }
    
    func releaseAntialiasedColorTexture() {
        currentFrameAntialiasedColor = nil
    }
    
    func resize(width: Int, height: Int) {
        if windowSize.width == width && windowSize.height == height {
            return
        }
        
        windowSize = MTLSize(width: width, height: height, depth: 1)
        aspectRatio = Float(windowSize.width) / Float(windowSize.height)
        
        let desc = MTLTextureDescriptor()
        desc.width = windowSize.width
        desc.height = windowSize.height
        desc.storageMode = .private
        desc.pixelFormat = .bgra8Unorm_srgb
        desc.usage = [ .renderTarget, .shaderRead, .shaderWrite ]
        currentFrameUpscaledColor = device.makeTexture(descriptor: desc)
        
        adjustRenderScale(renderScale)
    }
    
    func adjustRenderScale(_ newRenderScale: Float) {
        var width: Int = max(1280, Int(Float(windowSize.width) * newRenderScale))
        var height: Int = max(720, Int(Float(windowSize.height) * newRenderScale))
        
        // Preserve the aspect ratio by choosing the maximum scale for width or height.
        var adjustedRenderScale = max(Float(width) / Float(windowSize.width), Float(height) / Float(windowSize.height))
        if adjustedRenderScale > 1 {
            adjustedRenderScale = 1
        }
        width = Int(Float(windowSize.width) * adjustedRenderScale)
        height = Int(Float(windowSize.height) * adjustedRenderScale)
        
        if width == renderSize.width && height == renderSize.height {
            return
        }
        
        renderScale = adjustedRenderScale
        renderSize = MTLSize(width: width, height: height, depth: 1)
        
        let desc = MTLTextureDescriptor()
        desc.width = renderSize.width
        desc.height = renderSize.height
        desc.storageMode = .private
        
        desc.usage = [ .renderTarget, .shaderRead ]
        desc.pixelFormat = .bgra8Unorm_srgb
        currentFrameColor = device.makeTexture(descriptor: desc)!
        
        desc.usage = [ .renderTarget, .shaderRead ]
        desc.pixelFormat = .depth32Float
        currentFrameDepth = device.makeTexture(descriptor: desc)!
        
        desc.pixelFormat = .rg16Float
        desc.usage = [ .renderTarget, .shaderRead ]
        currentFrameMotion = device.makeTexture(descriptor: desc)
    }
    
    func renderPassDescriptorForRender(makeMotionVectors: Bool) -> MTLRenderPassDescriptor {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        
        renderPassDescriptor.colorAttachments[0].texture = currentFrameColor!
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0)
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadAction.clear
        if makeMotionVectors {
            renderPassDescriptor.colorAttachments[1].texture = currentFrameMotion!
            renderPassDescriptor.colorAttachments[1].loadAction = MTLLoadAction.clear
        }
        renderPassDescriptor.depthAttachment.texture = currentFrameDepth!
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        
        return renderPassDescriptor
    }
    
    /// Docs suggest MTK View does exist but nah
//    func renderPassDescriptor(_ view: MTKView) -> MTLRenderPassDescriptor {
 //       let renderPassDescriptor = view.currentRenderPassDescriptor!
 //       renderPassDescriptor.depthAttachment.texture = nil
 //       return renderPassDescriptor
 //   }
}
