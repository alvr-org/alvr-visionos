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
let renderScale = 2.25
let renderColorFormat = MTLPixelFormat.bgra8Unorm_srgb // rgba8Unorm, rgba8Unorm_srgb, bgra8Unorm, bgra8Unorm_srgb, rgba16Float
let renderDepthFormat = MTLPixelFormat.depth32Float
let renderViewCount = 1
let renderZNear = 0.001
let renderZFar = 100.0

class VisionPro: NSObject, ObservableObject {
    var nextFrameTime: TimeInterval = 0.0

    var vsyncDelta: Double = (1.0 / 90.0)
    var vsyncLatency: Double = (1.0 / 90.0) * 2
    
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
        var rkRenderTime = 0.014
        while rkRenderTime > 0.0 {
            curVsyncLatency += frameDuration
            rkRenderTime -= frameDuration
        }
        vsyncLatency = curVsyncLatency
        nextFrameTime = displaylink.targetTimestamp + vsyncLatency
        vsyncDelta = frameDuration
        //print("vsync frame", frameDuration, displaylink.targetTimestamp - CACurrentMediaTime(), displaylink.timestamp - CACurrentMediaTime())
    }
}

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let rk_panel_depth: Float = 100

class RealityKitClientSystem : System {
    let visionPro = VisionPro()
    var lastUpdateTime = 0.0
    var drawableQueue: TextureResource.DrawableQueue? = nil
    private(set) var surfaceMaterial: ShaderGraphMaterial? = nil
    private var textureResource: TextureResource?
    
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var depthTexture: MTLTexture
    var renderViewports: [MTLViewport] = [MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0), MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0)]
    
    //var renderTangents: [simd_float4] = [simd_float4(-1.0471973, 0.7853982, 0.7853982, -0.8726632), simd_float4(-0.7853982, 1.0471973, 0.7853982, -0.8726632)]
    var fullscreenQuadBuffer:MTLBuffer!
    var lastTexture: MTLTexture? = nil
    
    var frameIdx: Int = 0
    
    var currentRenderWidth: Int = Int(Double(renderWidth) * renderScale)
    var currentRenderHeight: Int = Int(Double(renderHeight) * renderScale)
    var currentRenderScale: Float = Float(renderScale)
    var currentSetRenderScale: Float = Float(renderScale)
    var lastRenderScale: Float = Float(renderScale)
    var lastFbChangeTime: Double = 0.0
    var lockOutRaising: Bool = false
    var dynamicallyAdjustRenderScale: Bool = false
    
    var reprojectedFramesInARow: Int = 0
    
    var lastSubmit = 0.0
    var lastLastSubmit = 0.0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    
    var renderer: Renderer;
    
    required init(scene: RealityKit.Scene) {
        self.renderer = Renderer(nil)

        //visionPro.createDisplayLink()
        let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: renderColorFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget, .shaderRead, .shaderWrite], mipmapsMode: .none)
        self.drawableQueue = try? TextureResource.DrawableQueue(desc)
        self.drawableQueue!.allowsNextDrawableTimeout = true
        
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
        
        // Create depth texture descriptor
        let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderDepthFormat,
                                                                              width: currentRenderWidth,
                                                                              height: currentRenderHeight*2,
                                                                              mipmapped: false)
        depthTextureDescriptor.usage = [.renderTarget, .shaderRead]
        depthTextureDescriptor.storageMode = .private
        self.depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)!
        
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

        renderer.rebuildRenderPipelines()

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }

    func update(context: SceneUpdateContext) {
        // RealityKit automatically calls this every frame for every scene.
        let plane = context.scene.findEntity(named: "video_plane") as? ModelEntity
        if let plane = plane {
            //print("frame", plane.id)
            
            do {
                if dynamicallyAdjustRenderScale && CACurrentMediaTime() - lastSubmit > 0.02 && lastSubmit - lastLastSubmit > 0.02 && CACurrentMediaTime() - lastFbChangeTime > 0.25 {
                    currentRenderScale -= 0.25
                }
                
                if lastRenderScale != currentRenderScale {
                    currentRenderWidth = Int(Double(renderWidth) * Double(currentRenderScale))
                    currentRenderHeight = Int(Double(renderHeight) * Double(currentRenderScale))
                
                    // Recreate framebuffer
                    let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: renderColorFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget, .shaderRead, .shaderWrite], mipmapsMode: .none)
                    self.drawableQueue = try? TextureResource.DrawableQueue(desc)
                    self.drawableQueue!.allowsNextDrawableTimeout = true
                    self.textureResource!.replace(withDrawables: self.drawableQueue!)
                    
                    // Create depth texture
                    let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderDepthFormat,
                                                                                          width: currentRenderWidth,
                                                                                          height: currentRenderHeight*2,
                                                                                          mipmapped: false)
                    depthTextureDescriptor.usage = [.renderTarget, .shaderRead]
                    depthTextureDescriptor.storageMode = .private
                    self.depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)!
                    
                    renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentRenderHeight), width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
                    renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
                    self.lastFbChangeTime = CACurrentMediaTime()
                    
                    print("Resolution changed to:", currentRenderWidth, "x", currentRenderHeight, "(", currentRenderScale, ")")
                }
                lastRenderScale = currentRenderScale
            
                let drawable = try drawableQueue?.nextDrawable()
                if drawable == nil {
                    return
                }
                
                let transform = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: visionPro.nextFrameTime)?.originFromAnchorTransform //visionPro.transformMatrix()
                if transform == nil {
                    return
                }
                var planeTransform = transform!
                planeTransform.columns.3 -= planeTransform.columns.2 * rk_panel_depth
                
                //print(String(format: "%.2f, %.2f, %.2f", planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z), CACurrentMediaTime() - lastUpdateTime)
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
                
                //drawNextTexture(drawable: drawable!, simdDeviceAnchor: transform, plane: plane, position: position, orientation: orientation, scale: scale)
                renderFrame(drawable: drawable!, plane: plane)
                drawable!.presentOnSceneUpdate()
            }
            catch {
            
            }
        }
    }
    
    // TODO: Share this with Renderer somehow
    func renderFrame(drawable: TextureResource.Drawable, plane: ModelEntity) {
        //print("renderFrame", roundTripRenderTime)
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
        
        /*guard let drawable = frame.queryDrawable() else {
            if queuedFrame != nil {
                EventHandler.shared.lastQueuedFrame = queuedFrame
            }
            return
        }*/
        
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
                    
                    let rebuildThread = Thread {
                        self.renderer.rebuildRenderPipelines()
                    }
                    rebuildThread.name = "Rebuild Render Pipelines Thread"
                    rebuildThread.start()
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
                    let rebuildThread = Thread {
                        self.renderer.rebuildRenderPipelines()
                    }
                    rebuildThread.name = "Rebuild Render Pipelines Thread"
                    rebuildThread.start()
                }
            }
        }
        
        //checkEyes(drawable: drawable)
        
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        EventHandler.shared.framesSinceLastDecode += 1
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        
        
        
        //let vsyncTime = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let vsyncTime = visionPro.nextFrameTime
        let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
        let vsyncTimeReported = visionPro.nextFrameTime //- (visionPro.vsyncDelta * 4)
        let vsyncTimeReportedNs = UInt64(vsyncTimeReported * Double(NSEC_PER_SEC))
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        let deviceAnchor = framePreviouslyPredictedPose ?? matrix_identity_float4x4
        //let deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if EventHandler.shared.alvrInitialized {
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms
        
            //let nowTs = CACurrentMediaTime()
            //let nowToVsync = vsyncTime - nowTs
            
            // Sometimes upload speeds can be less than optimal.
            // To compensate, we will send 3 predictions at a fixed interval and hope that
            // one of them is optimal enough to avoid a re-sent timestamp frame
            // TODO: revisit this
            //var interval = ((11.0 / 1000.0) / 3.0)
#if !targetEnvironment(simulator)
            //if queuedFrame != nil {
            //    interval = roundTripRenderTime / 3.0
            //}
#endif
            //let targetTimestampA = nowTs + ((nowToVsync / 3.0)*1.0) + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            //let realTargetTimestampA = nowTs + ((nowToVsync / 3.0)*1.0) + (Double(alvr_get_head_prediction_offset_ns()) / Double(NSEC_PER_SEC))
            //let targetTimestampB = nowTs + ((nowToVsync / 3.0)*2.0) + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            //let realTargetTimestampB = nowTs + ((nowToVsync / 3.0)*2.0) + (Double(alvr_get_head_prediction_offset_ns()) / Double(NSEC_PER_SEC))
            //let targetTimestampC = nowTs + ((nowToVsync / 3.0)*3.0) + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            //let realTargetTimestampC = nowTs + ((nowToVsync / 3.0)*3.0) + (Double(alvr_get_head_prediction_offset_ns()) / Double(NSEC_PER_SEC))
            //WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestampA, realTargetTimestamp: realTargetTimestampA, delay: 0.0)
            //WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestampB, realTargetTimestamp: realTargetTimestampB, delay: interval)
            //WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestampC, realTargetTimestamp: realTargetTimestampC, delay: interval*2.0)
            
            let rkLatencyLimit = WorldTracker.maxPredictionRK //UInt64(Double(visionPro.vsyncDelta * 6.0) * Double(NSEC_PER_SEC))
            let targetTimestamp = vsyncTime - visionPro.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), rkLatencyLimit)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, delay: 0.0)
        }
        
        let transform = deviceAnchor
        var planeTransform = transform
        planeTransform.columns.3 -= transform.columns.2 * rk_panel_depth
        
        var scale = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
        scale *= rk_panel_depth
        let orientation = simd_quatf(transform) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
        let position = simd_float3(planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z)
        
        let submitTime = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            if EventHandler.shared.alvrInitialized && queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame?.timestamp {
                let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                //print("Finished:", queuedFrame!.timestamp)
                //print((vsyncTime - CACurrentMediaTime()) * 1000.0)
                //print((CACurrentMediaTime() - submitTime) * 1000.0)
                alvr_report_submit(queuedFrame!.timestamp, vsyncTimeReportedNs &- currentTimeNs)
                EventHandler.shared.lastSubmittedTimestamp = queuedFrame!.timestamp
            }
            else {
                /*plane.position = position
                plane.orientation = orientation
                plane.scale = scale
                drawable.present()*/
            }
        }
        
        // List of reasons to not display a frame
        var frameIsSuitableForDisplaying = true
        //print(EventHandler.shared.lastIpd, WorldTracker.shared.worldTrackingAddedOriginAnchor, EventHandler.shared.framesRendered)
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
            //print("render")
            for i in 0..<DummyMetalRenderer.renderViewTransforms.count {
                //renderOverlay(eyeIdx: i, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4, simdDeviceAnchor: simdDeviceAnchor)
                //renderStreamingFrame(eyeIdx: i, colorTexture: drawable.texture, commandBuffer: commandBuffer, queuedFrame: queuedFrame, framePose: framePreviouslyPredictedPose ?? matrix_identity_float4x4, simdDeviceAnchor: deviceAnchor)

                let viewports = [renderViewports[i]]
                let viewTransforms = [DummyMetalRenderer.renderViewTransforms[i]]
                let viewTangents = [DummyMetalRenderer.renderTangents[i]]
                let framePose = framePreviouslyPredictedPose ?? matrix_identity_float4x4
                let simdDeviceAnchor = deviceAnchor
                let nearZ = renderZNear
                let farZ = renderZFar
                let rasterizationRateMap: MTLRasterizationRateMap? = nil
                renderer.renderStreamingFrame(i, commandBuffer: commandBuffer, renderTargetColor: drawable.texture, renderTargetDepth: depthTexture, viewports: viewports, viewTransforms: viewTransforms, viewTangents: viewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
            }
            
            
            /*if isReprojected && useApplesReprojection {
                LayerRenderer.Clock().wait(until: drawable.frameTiming.renderingDeadline)
            }*/
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
                //renderOverlay(eyeIdx: i, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4, simdDeviceAnchor: deviceAnchor)
                
                let viewports = [renderViewports[i]]
                let viewTransforms = [DummyMetalRenderer.renderViewTransforms[i]]
                let viewTangents = [DummyMetalRenderer.renderTangents[i]]
                let framePose = noFramePose
                let simdDeviceAnchor = deviceAnchor
                let nearZ = renderZNear
                let farZ = renderZFar
                let rasterizationRateMap: MTLRasterizationRateMap? = nil
                
                renderer.renderNothing(i, commandBuffer: commandBuffer, renderTargetColor: drawable.texture, renderTargetDepth: depthTexture, viewports: viewports, viewTransforms: viewTransforms, viewTangents: viewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor)
                
                
                renderer.renderOverlay(commandBuffer: commandBuffer, renderTargetColor: drawable.texture, renderTargetDepth: depthTexture, viewports: viewports, viewTransforms: viewTransforms, viewTangents: viewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
                //renderOverlay(eyeIdx: i, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4, simdDeviceAnchor: deviceAnchor)
            }
            
            //renderOverlay(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame, framePose: noFramePose ?? matrix_identity_float4x4)
            //renderStreamingFrameDepth(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame)
        }
        
        /*for i in 0..<DummyMetalRenderer.renderViewTransforms.count {
            renderOverlay(eyeIdx: i, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4, simdDeviceAnchor: deviceAnchor)
        }*/
        
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
        
        //commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // this is a load-bearing wait
        
        plane.position = position
        plane.orientation = orientation
        plane.scale = scale
        
        lastLastSubmit = lastSubmit
        lastSubmit = submitTime
    }
}
