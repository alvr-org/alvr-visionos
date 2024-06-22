//
//  ImmersiveSystem.swift
//  RealityKitShenanigans
//

import SwiftUI
import RealityKit
import ARKit
import QuartzCore
import Metal
import MetalKit
import Spatial
import AVFoundation

let renderWidthReal = Int(1920)
let renderHeightReal = Int(1824)
let renderWidth = Int(renderWidthReal+256+32+8+2) // TODO just use VRR to fix this, we have 256x80 pixels unused at the edges (IPD dependent?)
let renderHeight = Int(renderHeightReal+80+4)
let renderScale = 1.75
let renderColorFormatSDR = MTLPixelFormat.bgra8Unorm_srgb // rgba8Unorm, rgba8Unorm_srgb, bgra8Unorm, bgra8Unorm_srgb, rgba16Float
let renderColorFormatHDR = MTLPixelFormat.rgba16Float // bgr10_xr_srgb? rg11b10Float? rgb9e5?--rgb9e5 is probably not renderable.
let renderColorFormatDrawableSDR = renderColorFormatSDR
let renderColorFormatDrawableHDR = MTLPixelFormat.rgba16Float
let renderDepthFormat = MTLPixelFormat.depth16Unorm
let renderViewCount = 2
let renderZNear = 0.001
let renderZFar = 100.0
let rkFramesInFlight = 3
let renderDoStreamSSAA = true
let renderMultithreaded = false

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let rk_panel_depth: Float = 100

class VisionPro: NSObject, ObservableObject {
    var nextFrameTime: TimeInterval = 0.0

    var vsyncDelta: Double = (1.0 / 90.0)
    var vsyncLatency: Double = (1.0 / 90.0) * 2
    var lastVsyncTime: Double = 0.0
    var rkAvgRenderTime: Double = 0.014
    
    var vsyncCallback: ((Double, Double)->Void)? = nil
    
    override init() {
        super.init()
        self.createDisplayLink()
    }
    
    func createDisplayLink() {
        let displaylink = CADisplayLink(target: self, selector: #selector(frame))
        displaylink.add(to: .current, forMode: RunLoop.Mode.default)
    }
    
    @objc func frame(displaylink: CADisplayLink) {
        let frameDuration = displaylink.targetTimestamp - displaylink.timestamp
        
        // The OS rounds up the frame time from the RealityKit render time (usually 14ms)
        // to the nearest vsync interval. So for 90Hz this is usually 2 * vsync
        var rkRenderTime = rkAvgRenderTime
        var curVsyncLatency = 0.0
        while rkRenderTime > 0.0 {
            curVsyncLatency += frameDuration
            rkRenderTime -= frameDuration
        }
        vsyncLatency = curVsyncLatency
        nextFrameTime = displaylink.targetTimestamp + vsyncLatency
        vsyncDelta = frameDuration
        //print("vsync frame", frameDuration, displaylink.targetTimestamp - CACurrentMediaTime(), displaylink.timestamp - CACurrentMediaTime())
        
        if CACurrentMediaTime() - lastVsyncTime < 0.005 {
            return
        }
        lastVsyncTime = CACurrentMediaTime()
        
        if let vsyncCallback = vsyncCallback {
            vsyncCallback(nextFrameTime, vsyncLatency)
        }
    }
}

struct RKQueuedFrame {
    let texture: MTLTexture
    let depthTexture: MTLTexture
    let timestamp: UInt64
    let transform: simd_float4x4
    let vsyncTime: Double
    let vrrMap: MTLRasterizationRateMap
    let vrrBuffer: MTLBuffer
}

// Every WindowGroup technically counts as a Scene, which means
// we have to do Shenanigans to make sure that only the correct Scenes
// get associated with our per-frame system.
class RealityKitClientSystem : System {
    static var howManyScenesExist = 0
    var which = 0
    var timesTried = 0
    var s: RealityKitClientSystemCorrectlyAssociated? = nil

    required init(scene: RealityKit.Scene) {
        which = RealityKitClientSystem.howManyScenesExist
        RealityKitClientSystem.howManyScenesExist += 1
    }
    
    static func setup(_ content: RealityViewContent) async {
        
        await MainActor.run {
            let material = UnlitMaterial(color: .white)
            let material2 = UnlitMaterial(color: UIColor(white: 0.0, alpha: 1.0))
            
            let videoPlaneMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)
            let cubeMesh = MeshResource.generateBox(size: 1.0)
            try? cubeMesh.addInvertedNormals()
            
            let anchor = AnchorEntity(.head)
            anchor.anchoring.trackingMode = .continuous
            anchor.name = "backdrop_headanchor"
            anchor.position = simd_float3(0.0, 0.0, 0.0)
            
            let videoPlane = ModelEntity(mesh: videoPlaneMesh, materials: [material])
            videoPlane.name = "video_plane"
            videoPlane.components.set(MagicRealityKitClientSystemComponent())
            videoPlane.components.set(InputTargetComponent())
            videoPlane.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMesh)]))
            videoPlane.scale = simd_float3(0.0, 0.0, 0.0)

            let backdrop = ModelEntity(mesh: videoPlaneMesh, materials: [material2])
            backdrop.name = "backdrop_plane"
            backdrop.isEnabled = false
            
            anchor.addChild(backdrop)

            content.add(videoPlane)
            content.add(anchor)
        }
    }
    
    func update(context: SceneUpdateContext) {
        //print(which, context.deltaTime, s != nil)
        if s != nil {
            s?.update(context: context)
            return
        }
        
        if timesTried > 10 {
            return
        }
        
        // Was hoping that the Window scenes would update slower if I avoided the weird
        // magic enable-90Hz-mode calls, but this at least has one benefit of not relying
        // on names
        
        var hasMagic = false
        let query = EntityQuery(where: .has(MagicRealityKitClientSystemComponent.self))
        for _ in context.entities(matching: query, updatingSystemWhen: .rendering) {
            hasMagic = true
            break
        }
        
        if !hasMagic {
            timesTried += 1
            return
        }
        
        if s == nil {
            s = RealityKitClientSystemCorrectlyAssociated(scene: context.scene)
        }
    }
}

class RealityKitClientSystemCorrectlyAssociated : System {
    let visionPro = VisionPro()
    var lastUpdateTime = 0.0
    var drawableQueue: TextureResource.DrawableQueue? = nil
    private(set) var surfaceMaterial: ShaderGraphMaterial? = nil
    private var textureResource: TextureResource? = nil
    var passthroughPipelineState: MTLRenderPipelineState? = nil
    var passthroughPipelineStateHDR: MTLRenderPipelineState? = nil
    var passthroughPipelineStateWithAlpha: MTLRenderPipelineState? = nil
    var passthroughPipelineStateWithAlphaHDR: MTLRenderPipelineState? = nil
    
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var renderViewports: [MTLViewport] = [MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0), MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0)]

    var lastTexture: MTLTexture? = nil
    
    var frameIdx: Int = 0
    
    var currentOffscreenRenderWidth: Int = Int(Double(renderWidth) * renderScale)
    var currentOffscreenRenderHeight: Int = Int(Double(renderHeight) * renderScale)
    var currentOffscreenRenderScale: Float = Float(renderScale)
    var lastOffscreenRenderScale: Float = Float(renderScale)
    
    var rateMapParamSize: MTLSizeAndAlign = MTLSizeAndAlign(size: 24624, align: 0x10000)
    var currentRenderWidth: Int = Int(Double(renderWidth) * renderScale)
    var currentRenderHeight: Int = Int(Double(renderHeight) * renderScale)
    var currentRenderScale: Float = Float(renderScale)
    var currentSetRenderScale: Float = Float(renderScale)
    var currentRenderColorFormat = renderColorFormatSDR
    var currentDrawableRenderColorFormat = renderColorFormatDrawableSDR
    var lastRenderColorFormat = renderColorFormatSDR
    var lastRenderScale: Float = Float(renderScale)
    var lastFbChangeTime: Double = 0.0
    var lockOutRaising: Bool = false
    var dynamicallyAdjustRenderScale: Bool = false
    
    var rkFramePool = [(MTLTexture, MTLTexture, MTLBuffer)]()
    var rkFrameQueue = [RKQueuedFrame]()
    var rkFramePoolLock = NSObject()
    var blitLock = NSObject()
    
    var reprojectedFramesInARow: Int = 0
    
    var lastSubmit = 0.0
    var lastUpdate = 0.0
    var lastLastSubmit = 0.0
    var lastFrameQueueFillTime = 0.0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    
    var renderer: Renderer
    
    var renderTangents = [simd_float4(1.73205, 1.0, 1.0, 1.19175), simd_float4(1.0, 1.73205, 1.0, 1.19175)]
    
    required init(scene: RealityKit.Scene) {
        print("system init")
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = self.device.makeCommandQueue()!
        
        self.renderer = Renderer(nil)
        self.renderer.fadeInOverlayAlpha = 1.0
        renderer.rebuildRenderPipelines()
        let settings = ALVRClientApp.gStore.settings
        renderTangents = DummyMetalRenderer.renderTangents
        for i in 0..<renderTangents.count {
            renderTangents[i] *= settings.fovRenderScale
        }

        currentSetRenderScale = settings.realityKitRenderScale
        if settings.realityKitRenderScale <= 0.0 {
            currentRenderScale = Float(renderScale)
            dynamicallyAdjustRenderScale = true
        }
        else {
            currentRenderScale = currentSetRenderScale
            dynamicallyAdjustRenderScale = false
        }
        
        // TODO: SSAA after moving foveation out of frag shader?
        if renderDoStreamSSAA {
            if let event = EventHandler.shared.streamEvent?.STREAMING_STARTED {
                currentOffscreenRenderScale = Float(event.view_width) / Float(renderWidthReal)
                
                currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
                currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))
            }
        }
        else {
            currentOffscreenRenderScale = currentRenderScale
            
            currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
            currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))
        }
        
        let vrr = createVRR() // HACK
        
        currentRenderWidth = vrr.screenSize.width//Int(Double(renderWidth) * Double(currentRenderScale))
        currentRenderHeight = vrr.screenSize.height//Int(Double(renderHeight) * Double(currentRenderScale))
        currentRenderScale = Float(currentRenderWidth) / Float(renderWidth)
        
        currentRenderColorFormat = renderer.currentRenderColorFormat
        currentDrawableRenderColorFormat = renderer.currentDrawableRenderColorFormat
        lastRenderColorFormat = currentRenderColorFormat
        lastRenderScale = currentRenderScale
        lastOffscreenRenderScale = currentOffscreenRenderScale

        let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget], mipmapsMode: .none)
        self.drawableQueue = try? TextureResource.DrawableQueue(desc)
        self.drawableQueue!.allowsNextDrawableTimeout = true
        
        // Dummy texture
        let data = Data([0x00, 0x00, 0x00, 0xFF])
        self.textureResource = try! TextureResource(
            dimensions: .dimensions(width: 1, height: 1),
            format: .raw(pixelFormat: .bgra8Unorm),
            contents: .init(
                mipmapLevels: [
                    .mip(data: data, bytesPerRow: 4),
                ]
            )
        )

        //renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentOffscreenRenderHeight), width: Double(currentOffscreenRenderWidth), height: Double(currentOffscreenRenderHeight), znear: renderZNear, zfar: renderZFar)
        //renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentOffscreenRenderWidth), height: Double(currentOffscreenRenderHeight), znear: renderZNear, zfar: renderZFar)
        
        Task {
            self.surfaceMaterial = try! await ShaderGraphMaterial(
                named: "/Root/SBSMaterial",
                from: "SBSMaterial.usda"
            )
            try! self.surfaceMaterial!.setParameter(
                name: "texture",
                value: .textureResource(self.textureResource!)
            )
            textureResource!.replace(withDrawables: drawableQueue!)
        }

        self.visionPro.vsyncCallback = rkVsyncCallback
        
        recreateFramePool()
        createCopyShaderPipelines()
        
        print("Offscreen render res:", currentOffscreenRenderWidth, "x", currentOffscreenRenderHeight, "(", currentOffscreenRenderScale, ")")
        print("Offscreen render res foveated:", vrr.physicalSize(layer: 0).width, "x", vrr.physicalSize(layer: 0).height, "(", Float(vrr.physicalSize(layer: 0).width) / Float(renderWidth), ")")
        print("RK render res:", currentRenderWidth, "x", currentRenderHeight, "(", currentRenderScale, ")")

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }
    
    func createCopyShaderPipelines()
    {
        let vrrMap = createVRR() // HACK
        
        self.passthroughPipelineState = try! renderer.buildCopyPipelineWithDevice(device: device, colorFormat: renderColorFormatSDR, viewCount: 1, vrrScreenSize: vrrMap.screenSize, vrrPhysSize: vrrMap.physicalSize(layer: 0),  vertexShaderName: "copyVertexShader", fragmentShaderName: "copyFragmentShader")
        self.passthroughPipelineStateHDR = try! renderer.buildCopyPipelineWithDevice(device: device, colorFormat: renderColorFormatDrawableHDR, viewCount: 1, vrrScreenSize: vrrMap.screenSize, vrrPhysSize: vrrMap.physicalSize(layer: 0),  vertexShaderName: "copyVertexShader", fragmentShaderName: "copyFragmentShader")
    }
    
    func createVRR() -> MTLRasterizationRateMap {
        let descriptor = MTLRasterizationRateMapDescriptor()
        descriptor.label = "Offscreen VRR"

        currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
        currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))


        let layerWidth = Int(currentOffscreenRenderWidth / 256) * 256
        let layerHeight = Int(currentOffscreenRenderHeight / 256) * 256
        descriptor.screenSize = MTLSizeMake(layerWidth, layerHeight, 2)

        let zoneCounts = MTLSizeMake(256, 256, 2)
        for i in 0..<zoneCounts.depth {
            let layerDescriptor = MTLRasterizationRateLayerDescriptor(sampleCount: zoneCounts)
            
            
            let innerWidthX = 20//zoneCounts.width/2
            let innerWidthY = 25//zoneCounts.height/2
            let innerStartX = (zoneCounts.width - innerWidthX) / 2
            let innerEndX = (innerStartX + innerWidthX)
            let innerStartY = (zoneCounts.height - innerWidthY) / 2
            let innerEndY = (innerStartX + innerWidthY)
            
            let innerVal: Float = 1.0
            let outerVal: Float = 1.0
            let edgeValStepX: Float = outerVal/Float(innerStartY)
            let edgeValStepY: Float = outerVal/Float(innerStartX)
            
            for row in 0..<innerStartY {
                layerDescriptor.vertical[row] = Float(row) * edgeValStepY
            }
            for row in innerStartY..<innerEndY {
                layerDescriptor.vertical[row] = innerVal
            }
            for row in innerEndY..<zoneCounts.height {
                layerDescriptor.vertical[row] = Float(innerStartY - (row - innerEndY)) * edgeValStepY
            }
            
            for column in 0..<innerStartX {
                layerDescriptor.horizontal[column] = Float(column) * edgeValStepX
            }
            for column in innerStartX..<innerEndX {
                layerDescriptor.horizontal[column] = innerVal
            }
            for column in innerEndX..<zoneCounts.width {
                layerDescriptor.horizontal[column] = Float(innerStartX - (column - innerEndX)) * edgeValStepX
            }

            descriptor.setLayer(layerDescriptor, at: i)
        }
        
        guard let vrrMap = device.makeRasterizationRateMap(descriptor: descriptor) else {
            fatalError("Failed to make VRR map")
        }
        
        // Create a buffer for the rate map.
        rateMapParamSize = vrrMap.parameterDataSizeAndAlign

        // Use phys coordinates for viewport.
        renderViewports[0] = MTLViewport(originX: 0, originY: 0.0, width: Double(vrrMap.screenSize.width), height: Double(Int(Float(vrrMap.screenSize.height) / 1.0)), znear: renderZNear, zfar: renderZFar)
        renderViewports[1] = MTLViewport(originX: 0, originY: 0.0, width: Double(vrrMap.screenSize.width), height: Double(Int(Float(vrrMap.screenSize.height) / 1.0)), znear: renderZNear, zfar: renderZFar)
        
        // Keep a constant texture size, but allow the VRR to change the viewports
        // TODO: per-frame viewports.
        currentOffscreenRenderWidth = layerWidth//vrrMap.physicalSize(layer: 0).width
        currentOffscreenRenderHeight = layerHeight//vrrMap.physicalSize(layer: 0).height
        
        //print("Offscreen render res foveated:", currentOffscreenRenderWidth, "x", currentOffscreenRenderHeight, "(", currentOffscreenRenderScale, ")")
        return vrrMap
    }
    
    func recreateFramePool() {
        objc_sync_enter(rkFramePoolLock)
        let cnt = rkFramePool.count
        for _ in 0..<cnt {
            let (texture, depthTexture, vrrBuffer) = self.rkFramePool.removeFirst()
            if texture.width == currentOffscreenRenderWidth && texture.pixelFormat == currentRenderColorFormat {
                rkFramePool.append((texture, depthTexture, vrrBuffer))
            }
            else {
#if !targetEnvironment(simulator)
                texture.setPurgeableState(.volatile)
                depthTexture.setPurgeableState(.volatile)
#endif
            }
        }
        
        while rkFramePool.count > rkFramesInFlight {
            let (a, b, c) = self.rkFramePool.removeFirst()
#if !targetEnvironment(simulator)
            a.setPurgeableState(.volatile)
            b.setPurgeableState(.volatile)
            c.setPurgeableState(.volatile)
#endif
        }

        for _ in rkFramePool.count..<rkFramesInFlight {
            var texture: MTLTexture? = nil
            var depthTexture: MTLTexture? = nil
            
            let textureDesc = MTLTextureDescriptor()
            textureDesc.textureType = .type2DArray
            textureDesc.pixelFormat = currentRenderColorFormat
            textureDesc.width = currentOffscreenRenderWidth
            textureDesc.height = currentOffscreenRenderHeight
            textureDesc.depth = 1
            textureDesc.arrayLength = 2
            textureDesc.mipmapLevelCount = 1
            textureDesc.usage = [.renderTarget, .shaderRead]
            textureDesc.storageMode = .private
            
            let depthTextureDescriptor = MTLTextureDescriptor()
            depthTextureDescriptor.textureType = .type2DArray
            depthTextureDescriptor.pixelFormat = renderDepthFormat
            depthTextureDescriptor.width = currentRenderWidth
            depthTextureDescriptor.height = currentRenderHeight
            depthTextureDescriptor.depth = 1
            depthTextureDescriptor.arrayLength = 2
            depthTextureDescriptor.mipmapLevelCount = 1
            depthTextureDescriptor.usage = [.renderTarget]
            depthTextureDescriptor.storageMode = .private

            for _ in 0..<100 {
                // TODO: VRR the edges when FFR is enabled (or always)
                
                texture = device.makeTexture(descriptor: textureDesc)
#if !targetEnvironment(simulator)
                texture?.setPurgeableState(.volatile)
#endif
                if texture != nil {
                    break
                }
            }
            
            for _ in 0..<100 {
                depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)
#if !targetEnvironment(simulator)
                depthTexture?.setPurgeableState(.volatile)
#endif
                if depthTexture != nil {
                    break
                }
            }
            
            let vrrBuffer = device.makeBuffer(length: rateMapParamSize.size,
                                       options: MTLResourceOptions.storageModeShared)
            
            if texture == nil || depthTexture == nil || vrrBuffer == nil {
                print("Couldn't allocate all texture!!!")
                continue
            }
            
            print("allocated frame pool", rkFramePool.count)
        
            rkFramePool.append((texture!, depthTexture!, vrrBuffer!))
        }
        objc_sync_exit(rkFramePoolLock)
    }
    
    func rkVsyncCallback(nextFrameTime: Double, vsyncLatency: Double) {
        if !renderMultithreaded {
            return
        }
        Task {
            objc_sync_enter(self.rkFramePoolLock)
            if self.rkFramePool.isEmpty {
                objc_sync_exit(self.rkFramePoolLock)
                return
            }
            let (texture, depthTexture, vrrBuffer) = self.rkFramePool.removeFirst()
            objc_sync_exit(self.rkFramePoolLock)
            if self.renderFrame(drawableTexture: texture, depthTexture: depthTexture, vrrBuffer: vrrBuffer) == nil {
                objc_sync_enter(self.rkFramePoolLock)
                self.rkFramePool.append((texture, depthTexture, vrrBuffer))
                objc_sync_exit(self.rkFramePoolLock)
            }
        }
    }
    
    func copyTextureToTexture(_ commandBuffer: MTLCommandBuffer, _ from: MTLTexture, _ to: MTLTexture, _ vrrMapBuffer: MTLBuffer) {
        //vrrMap!.copyParameterData(buffer: vrrMapBuffer!, offset: 0)

        // Create a render pass descriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()

        // Configure the render pass descriptor
        renderPassDescriptor.colorAttachments[0].texture = to // Set the destination texture as the render target
        renderPassDescriptor.colorAttachments[0].loadAction = .clear // .load for partial copy
        renderPassDescriptor.colorAttachments[0].storeAction = .store // Store the render target after rendering
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)

        // Create a render command encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render command encoder")
        }
        renderEncoder.label = "Copy Texture to Texture"
        renderEncoder.pushDebugGroup("Copy Texture to Texture")
        renderEncoder.setRenderPipelineState(to.pixelFormat == renderColorFormatDrawableHDR ? passthroughPipelineStateHDR! : passthroughPipelineState!)
        renderEncoder.setFragmentTexture(from, index: 0)
        renderEncoder.setFragmentBuffer(vrrMapBuffer, offset: 0, index: BufferIndex.VRR.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    var rkFillUp = 2
    func update(context: SceneUpdateContext) {
        let startUpdateTime = CACurrentMediaTime()
        
        if renderMultithreaded {
            objc_sync_enter(self.blitLock)
        }
        defer {
            if renderMultithreaded {
                objc_sync_exit(self.blitLock)
            }
        }

        // RealityKit automatically calls this every frame for every scene.
        guard let plane = context.scene.findEntity(named: "video_plane") as? ModelEntity else {
            return
        }
        guard let backdrop = context.scene.findEntity(named: "backdrop_plane") as? ModelEntity else {
            return
        }
        let settings = ALVRClientApp.gStore.settings
        
        var commandBuffer: MTLCommandBuffer? = nil
        var frame: RKQueuedFrame? = nil
        
        do {
            if dynamicallyAdjustRenderScale && CACurrentMediaTime() - lastSubmit > 0.02 && lastSubmit - lastLastSubmit > 0.02 && CACurrentMediaTime() - lastFbChangeTime > 0.25 {
                currentRenderScale -= 0.25
            }
            
            // TODO: for some reason color format changes causes fps to drop to 45?
            if lastRenderScale != currentRenderScale || lastOffscreenRenderScale != currentOffscreenRenderScale || lastRenderColorFormat != currentRenderColorFormat {
                currentRenderWidth = currentOffscreenRenderWidth//Int(Double(renderWidth) * Double(currentRenderScale))
                currentRenderHeight = currentOffscreenRenderHeight//Int(Double(renderHeight) * Double(currentRenderScale))
                
                // TODO: SSAA after moving foveation out of frag shader?
                if !renderDoStreamSSAA {
                    currentOffscreenRenderScale = currentRenderScale
                }
                
                currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
                currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))
            
                // Recreate framebuffer
                let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget], mipmapsMode: .none)
                self.drawableQueue = try? TextureResource.DrawableQueue(desc)
                self.drawableQueue!.allowsNextDrawableTimeout = true
                self.textureResource!.replace(withDrawables: self.drawableQueue!)
                
                renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentOffscreenRenderHeight), width: Double(currentOffscreenRenderWidth), height: Double(currentOffscreenRenderHeight), znear: renderZNear, zfar: renderZFar)
                renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentOffscreenRenderWidth), height: Double(currentOffscreenRenderHeight), znear: renderZNear, zfar: renderZFar)
                self.lastFbChangeTime = CACurrentMediaTime()
                
                print("Resolution changed!")
                print("Offscreen render res:", currentOffscreenRenderWidth, "x", currentOffscreenRenderHeight, "(", currentOffscreenRenderScale, ")")
                print("RK render res:", currentRenderWidth, "x", currentRenderHeight, "(", currentRenderScale, ")")
                
                self.recreateFramePool()
            }
            lastRenderScale = currentRenderScale
            lastOffscreenRenderScale = currentOffscreenRenderScale
            lastRenderColorFormat = currentRenderColorFormat
            
            if !renderMultithreaded {
                objc_sync_enter(self.rkFramePoolLock)
                if !self.rkFramePool.isEmpty {
                    let (texture, depthTexture, vrrBuffer) = self.rkFramePool.removeFirst()
                    objc_sync_exit(self.rkFramePoolLock)
                    let pair = self.renderFrame(drawableTexture: texture, depthTexture: depthTexture, vrrBuffer: vrrBuffer)
                    commandBuffer = pair?.0
                    frame = pair?.1
                    if commandBuffer == nil {
                        self.rkFramePool.append((texture, depthTexture, vrrBuffer))
                        //print("no frame")
                    }
                }
                objc_sync_exit(self.rkFramePoolLock)
            }
            else {
                if rkFillUp > 0 {
                    rkFillUp -= 1
                    if rkFillUp <= 0 {
                        rkFillUp = 0
                        return
                    }
                }

                if rkFrameQueue.isEmpty {
                    if CACurrentMediaTime() - lastFrameQueueFillTime > 0.25 {
                        rkFillUp = 2
                        lastFrameQueueFillTime = CACurrentMediaTime()
                    }
                    return
                }
                
                if !rkFrameQueue.isEmpty {
                    while rkFrameQueue.count > 1 {
                        let pop = rkFrameQueue.removeFirst()
#if !targetEnvironment(simulator)
                        //pop.texture.setPurgeableState(.volatile)
                        //pop.depthTexture.setPurgeableState(.volatile)
#endif
                        if pop.texture.pixelFormat == currentRenderColorFormat && pop.texture.width == currentOffscreenRenderWidth && rkFramePool.count < rkFramesInFlight {
                            objc_sync_enter(self.rkFramePoolLock)
                            rkFramePool.append((pop.texture, pop.depthTexture, pop.vrrBuffer))
                            objc_sync_exit(self.rkFramePoolLock)
                        }
                    }
        
                    frame = rkFrameQueue.removeFirst()
                }
            }
            
            //print(commandBuffer == nil, frame == nil, rkFramePool.count)
            guard let frame = frame else {
                //print("no frame")
                return
            }
        
            let drawable = try drawableQueue?.nextDrawable()
            if drawable == nil {
                self.rkFramePool.append((frame.texture, frame.depthTexture, frame.vrrBuffer))
                return
            }
            
            if renderMultithreaded && EventHandler.shared.lastSubmittedTimestamp != frame.timestamp {
                alvr_report_compositor_start(frame.timestamp)
            }

            lastUpdateTime = CACurrentMediaTime()
            
            if let surfaceMaterial = surfaceMaterial {
                plane.model?.materials = [surfaceMaterial]
            }
            
            if lastSubmit == 0.0 {
                lastSubmit = CACurrentMediaTime() - visionPro.vsyncDelta
                EventHandler.shared.handleHeadsetRemovedOrReentry()
                EventHandler.shared.handleHeadsetEntered()
                //EventHandler.shared.kickAlvr() // HACK: RealityKit kills the audio :/
            }
            

            var planeTransform = frame.transform
            let timestamp = frame.timestamp
            let texture = frame.texture
            let depthTexture = frame.depthTexture
            var vsyncTime = frame.vsyncTime
            let vrrBuffer = frame.vrrBuffer
            
            planeTransform.columns.3 -= planeTransform.columns.2 * rk_panel_depth
            var scale = simd_float3(renderTangents[0].x + renderTangents[0].y, 1.0, renderTangents[0].z + renderTangents[0].w)
            scale *= rk_panel_depth
            let orientation = simd_quatf(planeTransform) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
            let position = simd_float3(planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z)
            
            if commandBuffer == nil {
                commandBuffer = commandQueue.makeCommandBuffer()
            }
            
            guard let commandBuffer = commandBuffer else {
                fatalError("Failed to create command buffer")
            }

#if !targetEnvironment(simulator)
            // Shouldn't be needed but just in case
            //texture.setPurgeableState(.nonVolatile)
            //depthTexture.setPurgeableState(.nonVolatile)
            //drawable!.texture.setPurgeableState(.nonVolatile)
            //vrrBuffer.setPurgeableState(.nonVolatile)
#endif
            
            copyTextureToTexture(commandBuffer, texture, drawable!.texture, vrrBuffer)

            let submitTime = CACurrentMediaTime()
            commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
                if EventHandler.shared.alvrInitialized /*&& EventHandler.shared.lastSubmittedTimestamp != timestamp*/ {
                    vsyncTime = self.visionPro.nextFrameTime
                    
                    let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                    let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
                    //print("Finished:", queuedFrame!.timestamp)
                    //print((vsyncTime - CACurrentMediaTime()) * 1000.0)
                    //print("blit", (CACurrentMediaTime() - submitTime) * 1000.0)
                    let lastRenderTime = (CACurrentMediaTime() - startUpdateTime) + self.visionPro.vsyncDelta
                    self.visionPro.rkAvgRenderTime = (self.visionPro.rkAvgRenderTime + lastRenderTime) * 0.5
                    Task {
                        alvr_report_submit(timestamp, vsyncTimeNs &- currentTimeNs)
                    }
                    
                    //print("blit roundtrip", CACurrentMediaTime() - self.lastUpdate, timestamp)
                    self.lastUpdate = CACurrentMediaTime()
            
                    EventHandler.shared.lastSubmittedTimestamp = timestamp
                }
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            plane.position = position
            plane.orientation = orientation
            plane.scale = scale
            
            if settings.chromaKeyEnabled {
                backdrop.isEnabled = false
            }
            else {
                // Place giant plane 1m behind the video feed
                backdrop.position = simd_float3(0.0, 0.0, rk_panel_depth + 1)
                backdrop.orientation = simd_quatf()
                backdrop.scale = simd_float3(rk_panel_depth + 1, rk_panel_depth + 1, rk_panel_depth + 1) * 100.0
                
                // Hopefully these optimize into consts to avoid allocations
                if renderer.fadeInOverlayAlpha >= 1.0 {
                    backdrop.isEnabled = false
                }
                else if renderer.fadeInOverlayAlpha <= 0.0 {
                    backdrop.isEnabled = true
                }
                else {
                    backdrop.isEnabled = false
                }
            }
            
            //drawable!.texture.setPurgeableState(.volatile)
            
            drawable!.presentOnSceneUpdate()

            objc_sync_enter(rkFramePoolLock)
#if !targetEnvironment(simulator)
            //texture.setPurgeableState(.volatile)
            //depthTexture.setPurgeableState(.volatile)
            //vrrBuffer.setPurgeableState(.volatile)
#endif
            if texture.pixelFormat == currentRenderColorFormat && texture.width == currentOffscreenRenderWidth /*&& rkFramePool.count < rkFramesInFlight*/ {
                rkFramePool.append((texture, depthTexture, vrrBuffer))
            }
            //print("presented")
            objc_sync_exit(rkFramePoolLock)
        }
        catch {
            if let frame = frame {
                rkFramePool.append((frame.texture, frame.depthTexture, frame.vrrBuffer))
            }
        }
        print("totals", context.deltaTime, CACurrentMediaTime() - startUpdateTime)
    }
    
    // TODO: Share this with Renderer somehow
    func renderFrame(drawableTexture: MTLTexture, depthTexture: MTLTexture, vrrBuffer: MTLBuffer) -> (MTLCommandBuffer, RKQueuedFrame)? {
        /// Per frame updates hare
        EventHandler.shared.framesRendered += 1
        var streamingActiveForFrame = EventHandler.shared.streamingActive
        var isReprojected = false
        
        var queuedFrame:QueuedFrame? = nil
        
        roundTripRenderTime = CACurrentMediaTime() - lastRoundTripRenderTimestamp
        lastRoundTripRenderTimestamp = CACurrentMediaTime()
        
        let startPollTime = CACurrentMediaTime()
        while true {
            sched_yield()
            
            // If visionOS skipped our last frame, let the queue fill up a bit
            if EventHandler.shared.lastQueuedFrame != nil {
                if EventHandler.shared.lastQueuedFrame!.timestamp != EventHandler.shared.lastSubmittedTimestamp && EventHandler.shared.frameQueue.count < 2 {
                    queuedFrame = EventHandler.shared.lastQueuedFrame
                    EventHandler.shared.framesRendered -= 1
                    isReprojected = false
                    break
                }
            }
            
            objc_sync_enter(EventHandler.shared.frameQueueLock)
            queuedFrame = EventHandler.shared.frameQueue.count > 0 ? EventHandler.shared.frameQueue.removeFirst() : nil
            objc_sync_exit(EventHandler.shared.frameQueueLock)
            if queuedFrame != nil {
                break
            }
            
            if CACurrentMediaTime() - startPollTime > 0.001 {
                //EventHandler.shared.framesRendered -= 1
                break
            }
        }
        
        // Recycle old frame with old timestamp/anchor (visionOS doesn't do timewarp for us?)
        if queuedFrame == nil && EventHandler.shared.lastQueuedFrame != nil {
            //print("Using last frame...")
            queuedFrame = EventHandler.shared.lastQueuedFrame
            EventHandler.shared.framesRendered -= 1
            isReprojected = true
        }
        
        if queuedFrame == nil && streamingActiveForFrame {
            streamingActiveForFrame = false
        }
        let renderingStreaming = streamingActiveForFrame && queuedFrame != nil
        
        if !renderMultithreaded && queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp {
            alvr_report_compositor_start(queuedFrame!.timestamp)
        }

        if EventHandler.shared.alvrInitialized && streamingActiveForFrame {
            let ipd = DummyMetalRenderer.renderViewTransforms.count > 1 ? simd_length(DummyMetalRenderer.renderViewTransforms[0].columns.3 - DummyMetalRenderer.renderViewTransforms[1].columns.3) : 0.063
            
            var needsPipelineRebuild = false
            if abs(EventHandler.shared.lastIpd - ipd) > 0.001 {
                print("Send view config")
                if EventHandler.shared.lastIpd != -1 {
                    print("IPD changed!", EventHandler.shared.lastIpd, "->", ipd)
                }
                else {
                    EventHandler.shared.framesRendered = 0
                    renderer.lastReconfigureTime = CACurrentMediaTime()
                    
                    needsPipelineRebuild = true
                }
                let leftAngles = atan(renderTangents[0])
                let rightAngles = DummyMetalRenderer.renderViewTransforms.count > 1 ? atan(renderTangents[1]) : leftAngles
                let leftFov = AlvrFov(left: -leftAngles.x, right: leftAngles.y, up: leftAngles.z, down: -leftAngles.w)
                let rightFov = AlvrFov(left: -rightAngles.x, right: rightAngles.y, up: rightAngles.z, down: -rightAngles.w)
                EventHandler.shared.viewFovs = [leftFov, rightFov]
                EventHandler.shared.viewTransforms = [DummyMetalRenderer.renderViewTransforms[0], DummyMetalRenderer.renderViewTransforms.count > 1 ? DummyMetalRenderer.renderViewTransforms[1] : DummyMetalRenderer.renderViewTransforms[0]]
                EventHandler.shared.lastIpd = ipd
            }
            
            let settings = ALVRClientApp.gStore.settings
            
            if currentSetRenderScale != settings.realityKitRenderScale {
                currentSetRenderScale = settings.realityKitRenderScale
                if settings.realityKitRenderScale <= 0.0 {
                    currentRenderScale = Float(renderScale)
                    dynamicallyAdjustRenderScale = true
                }
                else {
                    currentRenderScale = currentSetRenderScale
                    dynamicallyAdjustRenderScale = false
                }
            }

            if CACurrentMediaTime() - renderer.lastReconfigureTime > 1.0 && (settings.chromaKeyEnabled != renderer.chromaKeyEnabled || settings.chromaKeyColorR != renderer.chromaKeyColor.x || settings.chromaKeyColorG != renderer.chromaKeyColor.y || settings.chromaKeyColorB != renderer.chromaKeyColor.z || settings.chromaKeyDistRangeMin != renderer.chromaKeyLerpDistRange.x || settings.chromaKeyDistRangeMax != renderer.chromaKeyLerpDistRange.y) {
                renderer.lastReconfigureTime = CACurrentMediaTime()
                needsPipelineRebuild = true
            }
            
            if needsPipelineRebuild {
                self.renderer.rebuildRenderPipelines()
                self.currentRenderColorFormat = self.renderer.currentRenderColorFormat
                self.currentDrawableRenderColorFormat = self.renderer.currentDrawableRenderColorFormat
                self.recreateFramePool()
                createCopyShaderPipelines()
            }
        }
        
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        EventHandler.shared.framesSinceLastDecode += 1
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        
        let vsyncTime = visionPro.nextFrameTime
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        var deviceAnchor = framePreviouslyPredictedPose ?? matrix_identity_float4x4
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if EventHandler.shared.alvrInitialized {
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms
            
            let rkLatencyLimit = WorldTracker.maxPredictionRK //UInt64(Double(visionPro.vsyncDelta * 6.0) * Double(NSEC_PER_SEC))
            let handAnchorLatencyLimit = WorldTracker.maxPrediction //UInt64(Double(visionPro.vsyncDelta * 6.0) * Double(NSEC_PER_SEC))
            let targetTimestamp = vsyncTime - visionPro.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), rkLatencyLimit)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime - visionPro.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), handAnchorLatencyLimit)) / Double(NSEC_PER_SEC))
            
            // Make overlay look smooth (at the cost of timewarp)
            if renderer.fadeInOverlayAlpha > 0.0 {
                anchorTimestamp = vsyncTime
            }
            
            let sentAnchor = WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)
            
            // Make overlay look correct
            if renderer.fadeInOverlayAlpha > 0.0 || deviceAnchor == matrix_identity_float4x4 {
                deviceAnchor = sentAnchor
            }
        }
        
        // Fallback
        if renderer.fadeInOverlayAlpha > 0.0 && deviceAnchor == matrix_identity_float4x4 {
            deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)?.originFromAnchorTransform ?? matrix_identity_float4x4
        }
        
        if currentRenderColorFormat != lastRenderColorFormat {
            return nil
        }
        
        if isReprojected && renderer.fadeInOverlayAlpha <= 0.0 {
            return nil
        }
        
        EventHandler.shared.totalFramesRendered += 1
        
        let planeTransform = deviceAnchor
        
        // List of reasons to not display a frame
        var frameIsSuitableForDisplaying = true
        if EventHandler.shared.lastIpd == -1 || EventHandler.shared.framesRendered < 90 {
            // Don't show frame if we haven't sent the view config and received frames
            // with that config applied.
            frameIsSuitableForDisplaying = false
            print("IPD is bad, no frame")
        }
        if !WorldTracker.shared.worldTrackingAddedOriginAnchor && EventHandler.shared.framesRendered < 300 {
            // Don't show frame if we haven't figured out our origin yet.
            frameIsSuitableForDisplaying = false
            print("Origin is bad, no frame")
        }
        if EventHandler.shared.videoFormat == nil {
            frameIsSuitableForDisplaying = false
            print("Missing video format, no frame")
        }
        
        if let videoFormat = EventHandler.shared.videoFormat {
            renderer.currentYuvTransform = VideoHandler.getYUVTransformForVideoFormat(videoFormat)
        }
        
        // TODO: why does this cause framerate to go down to 45?
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

#if !targetEnvironment(simulator)
        drawableTexture.setPurgeableState(.nonVolatile)
        depthTexture.setPurgeableState(.nonVolatile)
#endif

        let vrrMap = createVRR()
        vrrMap.copyParameterData(buffer: vrrBuffer, offset: 0)
        
        if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
            let framePose = framePreviouslyPredictedPose ?? matrix_identity_float4x4
            let simdDeviceAnchor = deviceAnchor
            let nearZ = renderZNear
            let farZ = renderZFar
            
            let allViewports = renderViewports
            let allViewTransforms = DummyMetalRenderer.renderViewTransforms
            let allViewTangents = renderTangents
            let rasterizationRateMap: MTLRasterizationRateMap? = vrrMap

            if let encoder = renderer.beginRenderStreamingFrame(0, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor) {
                
                    
                renderer.renderStreamingFrame(0, commandBuffer: commandBuffer, renderEncoder: encoder, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
                
                renderer.endRenderStreamingFrame(renderEncoder: encoder)
            }
            
            
            renderer.renderStreamingFrameOverlays(0, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
            

            if isReprojected {
                reprojectedFramesInARow += 1
                if reprojectedFramesInARow > 90 {
                    renderer.fadeInOverlayAlpha += 0.02
                }
            }
            else {
                reprojectedFramesInARow = 0
                renderer.fadeInOverlayAlpha -= 0.02
            }
        }
        else
        {
            reprojectedFramesInARow = 0;

            let noFramePose = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)?.originFromAnchorTransform ?? matrix_identity_float4x4
            // TODO: draw a cool loading logo
            // TODO: maybe also show the room in wireframe or something cool here
            
            if EventHandler.shared.totalFramesRendered > 300 {
                renderer.fadeInOverlayAlpha += 0.02
            }
            
            let allViewports = renderViewports
            let allViewTransforms = DummyMetalRenderer.renderViewTransforms
            let allViewTangents = renderTangents
            let framePose = noFramePose
            let simdDeviceAnchor = deviceAnchor
            let nearZ = renderZNear
            let farZ = renderZFar
            let rasterizationRateMap: MTLRasterizationRateMap? = vrrMap

            renderer.renderNothing(0, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor)
            
            renderer.renderOverlay(commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        }
        
        renderer.coolPulsingColorsTime += 0.005
        if renderer.coolPulsingColorsTime > 4.0 {
            renderer.coolPulsingColorsTime = 0.0
        }
        
        if renderer.fadeInOverlayAlpha > 1.0 {
            renderer.fadeInOverlayAlpha = 1.0
        }
        if renderer.fadeInOverlayAlpha < 0.0 {
            renderer.fadeInOverlayAlpha = 0.0
        }

        EventHandler.shared.lastQueuedFrame = queuedFrame // crashed once?
        EventHandler.shared.lastQueuedFramePose = framePreviouslyPredictedPose
        
        let submitTime = CACurrentMediaTime()
        
        if renderMultithreaded {
            commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
                //print("render", (CACurrentMediaTime() - submitTime) * 1000.0)
                let timestamp = queuedFrame?.timestamp ?? 0
                let queuedFrame = RKQueuedFrame(texture: drawableTexture, depthTexture: depthTexture, timestamp: timestamp, transform: planeTransform, vsyncTime: self.visionPro.nextFrameTime, vrrMap: vrrMap, vrrBuffer: vrrBuffer)
                
                // Not sure why this needs to be a task
                Task {
                    objc_sync_enter(self.blitLock)
                    if timestamp >= self.rkFrameQueue.last?.timestamp ?? timestamp {
                        self.rkFrameQueue.append(queuedFrame)
                    }
                    objc_sync_exit(self.blitLock)
                }
            }
            commandBuffer.commit()
        }
        
        //print(submitTime - lastSubmit)
        
        lastLastSubmit = lastSubmit
        lastSubmit = submitTime
        
        let timestamp = queuedFrame?.timestamp ?? 0
        let rkQueuedFrame = RKQueuedFrame(texture: drawableTexture, depthTexture: depthTexture, timestamp: timestamp, transform: planeTransform, vsyncTime: self.visionPro.nextFrameTime, vrrMap: vrrMap, vrrBuffer: vrrBuffer)
        
        return (commandBuffer, rkQueuedFrame)
    }
}
