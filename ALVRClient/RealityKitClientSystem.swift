//
//  ImmersiveSystem.swift
//  RealityKitShenanigans
//

import RealityKit
import ARKit
import QuartzCore
import Metal
import MetalKit
import Spatial
import AVFoundation

let renderWidth = Int(1920)
let renderHeight = Int(1840)
let renderScale = 1.75
let renderColorFormatSDR = MTLPixelFormat.bgra8Unorm_srgb // rgba8Unorm, rgba8Unorm_srgb, bgra8Unorm, bgra8Unorm_srgb, rgba16Float
let renderColorFormatHDR = MTLPixelFormat.rgba16Float // bgr10_xr_srgb? rg11b10Float? rgb9e5?--rgb9e5 is probably not renderable.
let renderColorFormatDrawableSDR = renderColorFormatSDR
let renderColorFormatDrawableHDR = MTLPixelFormat.rgba16Float
let renderDepthFormat = MTLPixelFormat.depth16Unorm
let renderViewCount = 1
let renderZNear = 0.001
let renderZFar = 100.0

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let rk_panel_depth: Float = 100

class VisionPro: NSObject, ObservableObject {
    var nextFrameTime: TimeInterval = 0.0

    var vsyncDelta: Double = (1.0 / 90.0)
    var vsyncLatency: Double = (1.0 / 90.0) * 2
    var lastVsyncTime: Double = 0.0
    
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
        var curVsyncLatency = 0.0
        var rkRenderTime = 0.004
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
}

class RealityKitClientSystem : System {
    let visionPro = VisionPro()
    var lastUpdateTime = 0.0
    var drawableQueue: TextureResource.DrawableQueue? = nil
    private(set) var surfaceMaterial: ShaderGraphMaterial? = nil
    private var textureResource: TextureResource?
    let passthroughPipelineState: MTLRenderPipelineState
    let passthroughPipelineStateHDR: MTLRenderPipelineState
    
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var renderViewports: [MTLViewport] = [MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0), MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0)]
    
    var fullscreenQuadBuffer:MTLBuffer!
    var lastTexture: MTLTexture? = nil
    
    var frameIdx: Int = 0
    
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
    
    var rkFramePool = [(MTLTexture, MTLTexture)]()
    var rkFrameQueue = [RKQueuedFrame]()
    var rkFramePoolLock = NSObject()
    
    var reprojectedFramesInARow: Int = 0
    
    var lastSubmit = 0.0
    var lastUpdate = 0.0
    var lastLastSubmit = 0.0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    
    var renderer: Renderer;
    
    required init(scene: RealityKit.Scene) {
        self.renderer = Renderer(nil)
        renderer.rebuildRenderPipelines()
        currentRenderColorFormat = renderer.currentRenderColorFormat
        currentDrawableRenderColorFormat = renderer.currentDrawableRenderColorFormat
        lastRenderColorFormat = currentRenderColorFormat

        let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget, .shaderRead, .shaderWrite], mipmapsMode: .none)
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

        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = self.device.makeCommandQueue()!
        
        // Copy texture pipelines
        self.passthroughPipelineState = try! Renderer.buildCopyPipelineWithDevice(device: device, colorFormat: renderColorFormatSDR)
        self.passthroughPipelineStateHDR = try! Renderer.buildCopyPipelineWithDevice(device: device, colorFormat: renderColorFormatDrawableHDR)

        renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentRenderHeight), width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
        renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
        
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

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }
    
    func recreateFramePool() {
        print("recreate frame pool")
        objc_sync_enter(rkFramePoolLock)
        let cnt = rkFramePool.count
        for _ in 0..<cnt {
            let (texture, depthTexture) = self.rkFramePool.removeFirst()
            if texture.width == currentRenderWidth && texture.pixelFormat == currentRenderColorFormat {
                rkFramePool.append((texture, depthTexture))
            }
        }
        
        while rkFramePool.count > 4 {
            self.rkFramePool.removeFirst()
        }

        for _ in rkFramePool.count..<4 {
            let textureDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: currentRenderColorFormat,
                                                                                  width: currentRenderWidth,
                                                                                  height: currentRenderHeight*2,
                                                                                  mipmapped: false)
            textureDesc.usage = [.renderTarget, .shaderRead]
            textureDesc.storageMode = .private
            
            let texture = device.makeTexture(descriptor: textureDesc)!
            
            let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderDepthFormat,
                                                                              width: currentRenderWidth,
                                                                              height: currentRenderHeight*2,
                                                                              mipmapped: false)
            depthTextureDescriptor.usage = [.renderTarget, .shaderRead]
            depthTextureDescriptor.storageMode = .private
            let depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)!
        
            rkFramePool.append((texture, depthTexture))
        }
        objc_sync_exit(rkFramePoolLock)
    }
    
    func rkVsyncCallback(nextFrameTime: Double, vsyncLatency: Double) {
        Task {
            objc_sync_enter(self.rkFramePoolLock)
            if self.rkFramePool.isEmpty {
                objc_sync_exit(self.rkFramePoolLock)
                return
            }
            let (texture, depthTexture) = self.rkFramePool.removeFirst()
            objc_sync_exit(self.rkFramePoolLock)
            if self.renderFrame(drawableTexture: texture, depthTexture: depthTexture) == nil {
                objc_sync_enter(self.rkFramePoolLock)
                self.rkFramePool.append((texture, depthTexture))
                objc_sync_exit(self.rkFramePoolLock)
            }
        }
    }

    func update(context: SceneUpdateContext) {
        // RealityKit automatically calls this every frame for every scene.
        let plane = context.scene.findEntity(named: "video_plane") as? ModelEntity
        if let plane = plane {
            do {
                if dynamicallyAdjustRenderScale && CACurrentMediaTime() - lastSubmit > 0.02 && lastSubmit - lastLastSubmit > 0.02 && CACurrentMediaTime() - lastFbChangeTime > 0.25 {
                    currentRenderScale -= 0.25
                }
                
                // TODO: for some reason color format changes causes fps to drop to 45? 
                if lastRenderScale != currentRenderScale || lastRenderColorFormat != currentRenderColorFormat {
                    currentRenderWidth = Int(Double(renderWidth) * Double(currentRenderScale))
                    currentRenderHeight = Int(Double(renderHeight) * Double(currentRenderScale))
                
                    // Recreate framebuffer
                    let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget, .shaderRead], mipmapsMode: .none)
                    self.drawableQueue = try? TextureResource.DrawableQueue(desc)
                    self.drawableQueue!.allowsNextDrawableTimeout = true
                    self.textureResource!.replace(withDrawables: self.drawableQueue!)
                    
                    renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentRenderHeight), width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
                    renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
                    self.lastFbChangeTime = CACurrentMediaTime()
                    
                    print("Resolution changed to:", currentRenderWidth, "x", currentRenderHeight, "(", currentRenderScale, ")")
                    
                    self.recreateFramePool()
                }
                lastRenderScale = currentRenderScale
                lastRenderColorFormat = currentRenderColorFormat
                
                if rkFrameQueue.isEmpty {
                    return
                }
            
                let drawable = try drawableQueue?.nextDrawable()
                if drawable == nil {
                    return
                }

                lastUpdateTime = CACurrentMediaTime()
                
                if let surfaceMaterial = surfaceMaterial {
                    plane.model?.materials = [surfaceMaterial]
                }
                
                if lastSubmit == 0.0 {
                    lastSubmit = CACurrentMediaTime() - visionPro.vsyncDelta
                    EventHandler.shared.handleHeadsetRemovedOrReentry()
                    EventHandler.shared.handleHeadsetEntered()
                    EventHandler.shared.kickAlvr() // HACK: RealityKit kills the audio :/
                }
                
                if !rkFrameQueue.isEmpty {
                    while rkFrameQueue.count > 1 {
                        let pop = rkFrameQueue.removeFirst()
                        if pop.texture.pixelFormat == currentRenderColorFormat && pop.texture.width == currentRenderWidth && rkFramePool.count < 4 {
                            objc_sync_enter(self.rkFramePoolLock)
                            rkFramePool.append((pop.texture, pop.depthTexture))
                            objc_sync_exit(self.rkFramePoolLock)
                        }
                    }
        
                    let frame = rkFrameQueue.removeFirst()
                    var planeTransform = frame.transform
                    let timestamp = frame.timestamp
                    let texture = frame.texture
                    let depthTexture = frame.depthTexture
                    var vsyncTime = frame.vsyncTime
                    
                    if frame.texture.width != drawable!.texture.width {
                        return
                    }
                    
                    planeTransform.columns.3 -= planeTransform.columns.2 * rk_panel_depth
                    var scale = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
                    scale *= rk_panel_depth
                    let orientation = simd_quatf(planeTransform) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
                    let position = simd_float3(planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z)
                    
                    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                        fatalError("Failed to create command buffer")
                    }

                    // Create a render pass descriptor
                    let renderPassDescriptor = MTLRenderPassDescriptor()

                    // Configure the render pass descriptor
                    renderPassDescriptor.colorAttachments[0].texture = drawable!.texture // Set the destination texture as the render target
                    renderPassDescriptor.colorAttachments[0].loadAction = .clear // Clear the render target
                    renderPassDescriptor.colorAttachments[0].storeAction = .store // Store the render target after rendering

                    // Create a render command encoder
                    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                        fatalError("Failed to create render command encoder")
                    }
                    renderEncoder.setRenderPipelineState(drawable!.texture.pixelFormat == renderColorFormatDrawableHDR ? passthroughPipelineStateHDR : passthroughPipelineState)
                    renderEncoder.setFragmentTexture(texture, index: 0)
                    renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    renderEncoder.endEncoding()

                    let submitTime = CACurrentMediaTime()
                    commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
                        if EventHandler.shared.alvrInitialized && EventHandler.shared.lastSubmittedTimestamp != timestamp {
                            vsyncTime = self.visionPro.nextFrameTime
                            
                            let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                            let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
                            //print("Finished:", queuedFrame!.timestamp)
                            //print((vsyncTime - CACurrentMediaTime()) * 1000.0)
                            //print((CACurrentMediaTime() - submitTime) * 1000.0)
                            Task {
                                alvr_report_submit(timestamp, vsyncTimeNs &- currentTimeNs)
                            }
                            
                            //print(CACurrentMediaTime() - self.lastUpdate, timestamp)
                            self.lastUpdate = CACurrentMediaTime()
                    
                            EventHandler.shared.lastSubmittedTimestamp = timestamp
                        }
                    }
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    
                    plane.position = position
                    plane.orientation = orientation
                    plane.scale = scale
                    
                    drawable!.presentOnSceneUpdate()
                    
                    
                    
                    objc_sync_enter(rkFramePoolLock)
                    //print(texture.width, currentRenderWidth)
                    if texture.pixelFormat == currentRenderColorFormat && texture.width == currentRenderWidth && rkFramePool.count < 4 {
                        rkFramePool.append((texture, depthTexture))
                    }
                    objc_sync_exit(rkFramePoolLock)
                }
            }
            catch {
            
            }
        }
    }
    
    // TODO: Share this with Renderer somehow
    func renderFrame(drawableTexture: MTLTexture, depthTexture: MTLTexture) -> (UInt64, simd_float4x4)? {
        /// Per frame updates hare
        EventHandler.shared.framesRendered += 1
        EventHandler.shared.totalFramesRendered += 1
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
            
            if CACurrentMediaTime() - startPollTime > 0.005 {
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
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }
        
        if queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp {
            alvr_report_compositor_start(queuedFrame!.timestamp)
        }

        if EventHandler.shared.alvrInitialized && streamingActiveForFrame {
            let ipd = DummyMetalRenderer.renderViewTransforms.count > 1 ? simd_length(DummyMetalRenderer.renderViewTransforms[0].columns.3 - DummyMetalRenderer.renderViewTransforms[1].columns.3) : 0.063
            if abs(EventHandler.shared.lastIpd - ipd) > 0.001 {
                print("Send view config")
                if EventHandler.shared.lastIpd != -1 {
                    print("IPD changed!", EventHandler.shared.lastIpd, "->", ipd)
                }
                else {
                    EventHandler.shared.framesRendered = 0
                    renderer.lastReconfigureTime = CACurrentMediaTime()
                    
                    //let rebuildThread = Thread {
                        self.renderer.rebuildRenderPipelines()
                        self.currentRenderColorFormat = self.renderer.currentRenderColorFormat
                        self.currentDrawableRenderColorFormat = self.renderer.currentDrawableRenderColorFormat
                        self.recreateFramePool()
                    //}
                    //rebuildThread.name = "Rebuild Render Pipelines Thread"
                    //rebuildThread.start()
                }
                let leftAngles = atan(DummyMetalRenderer.renderTangents[0])
                let rightAngles = DummyMetalRenderer.renderViewTransforms.count > 1 ? atan(DummyMetalRenderer.renderTangents[1]) : leftAngles
                let leftFov = AlvrFov(left: -leftAngles.x, right: leftAngles.y, up: leftAngles.z, down: -leftAngles.w)
                let rightFov = AlvrFov(left: -rightAngles.x, right: rightAngles.y, up: rightAngles.z, down: -rightAngles.w)
                EventHandler.shared.viewFovs = [leftFov, rightFov]
                EventHandler.shared.viewTransforms = [DummyMetalRenderer.renderViewTransforms[0], DummyMetalRenderer.renderViewTransforms.count > 1 ? DummyMetalRenderer.renderViewTransforms[1] : DummyMetalRenderer.renderViewTransforms[0]]
                EventHandler.shared.lastIpd = ipd
            }
            
            if let settings = WorldTracker.shared.settings {
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
                    //let rebuildThread = Thread {
                        self.renderer.rebuildRenderPipelines()
                        self.currentRenderColorFormat = self.renderer.currentRenderColorFormat
                        self.currentDrawableRenderColorFormat = self.renderer.currentDrawableRenderColorFormat
                        self.recreateFramePool()
                    //}
                    //rebuildThread.name = "Rebuild Render Pipelines Thread"
                    //rebuildThread.start()
                }
            }
        }
        
        if currentRenderColorFormat != lastRenderColorFormat {
            return nil
        }
        
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        EventHandler.shared.framesSinceLastDecode += 1
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        
        let vsyncTime = visionPro.nextFrameTime
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        //let deviceAnchor = framePreviouslyPredictedPose ?? matrix_identity_float4x4
        let deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if EventHandler.shared.alvrInitialized {
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms
            
            let rkLatencyLimit = WorldTracker.maxPredictionRK //UInt64(Double(visionPro.vsyncDelta * 6.0) * Double(NSEC_PER_SEC))
            let targetTimestamp = vsyncTime - visionPro.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), rkLatencyLimit)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, delay: 0.0)
        }
        
        let planeTransform = deviceAnchor
        
        let submitTime = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            //print((CACurrentMediaTime() - submitTime) * 1000.0)
            let timestamp = queuedFrame?.timestamp ?? 0
            let queuedFrame = RKQueuedFrame(texture: drawableTexture, depthTexture: depthTexture, timestamp: timestamp, transform: planeTransform, vsyncTime: self.visionPro.nextFrameTime)
            if timestamp >= self.rkFrameQueue.last?.timestamp ?? timestamp {
                self.rkFrameQueue.append(queuedFrame)
            }
        }
        
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
        
        if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
            for i in 0..<DummyMetalRenderer.renderViewTransforms.count {
                let viewports = [renderViewports[i]]
                let viewTransforms = [DummyMetalRenderer.renderViewTransforms[i]]
                let viewTangents = [DummyMetalRenderer.renderTangents[i]]
                let framePose = framePreviouslyPredictedPose ?? matrix_identity_float4x4
                let simdDeviceAnchor = deviceAnchor
                let nearZ = renderZNear
                let farZ = renderZFar
                let rasterizationRateMap: MTLRasterizationRateMap? = nil
                renderer.renderStreamingFrame(i, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: viewports, viewTransforms: viewTransforms, viewTangents: viewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
            }

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
            
            for i in 0..<DummyMetalRenderer.renderViewTransforms.count {
                let viewports = [renderViewports[i]]
                let viewTransforms = [DummyMetalRenderer.renderViewTransforms[i]]
                let viewTangents = [DummyMetalRenderer.renderTangents[i]]
                let framePose = noFramePose
                let simdDeviceAnchor = deviceAnchor
                let nearZ = renderZNear
                let farZ = renderZFar
                let rasterizationRateMap: MTLRasterizationRateMap? = nil
                
                renderer.renderNothing(i, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: viewports, viewTransforms: viewTransforms, viewTangents: viewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor)
                
                renderer.renderOverlay(commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: viewports, viewTransforms: viewTransforms, viewTangents: viewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
            }
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

        EventHandler.shared.lastQueuedFrame = queuedFrame
        EventHandler.shared.lastQueuedFramePose = framePreviouslyPredictedPose
        
        commandBuffer.commit()
        
        lastLastSubmit = lastSubmit
        lastSubmit = submitTime
        
        return (queuedFrame?.timestamp ?? 0, planeTransform)
    }
}
