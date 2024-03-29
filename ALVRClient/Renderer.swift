//
//  Renderer.swift
//
import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import ARKit
import VideoToolbox
import ObjectiveC

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
let alignedPlaneUniformSize = (MemoryLayout<PlaneUniform>.size + 0xFF) & -0x100
let alignedEncodingUniformSize = (MemoryLayout<EncodingUniform>.size + 0xFF) & -0x100

let maxBuffersInFlight = 3
let maxPlanesDrawn = 512

enum RendererError: Error {
    case badVertexDescriptor
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let panel_depth: Float = 1

// TODO(zhuowei): what's the z supposed to be?
// x, y, z
// u, v
let fullscreenQuadVertices:[Float] = [-panel_depth, -panel_depth, -panel_depth,
                                       panel_depth, -panel_depth, -panel_depth,
                                       -panel_depth, panel_depth, -panel_depth,
                                       panel_depth, panel_depth, -panel_depth,
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

class Renderer {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var pipelineState: MTLRenderPipelineState
    var depthStateAlways: MTLDepthStencilState
    var depthStateGreater: MTLDepthStencilState
    var colorMap: MTLTexture

    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>
    
    var dynamicPlaneUniformBuffer: MTLBuffer
    var planeUniformBufferOffset = 0
    var planeUniformBufferIndex = 0
    var planeUniforms: UnsafeMutablePointer<PlaneUniform>
    
    var dynamicEncodingUniformBuffer: MTLBuffer
    var encodingUniformBufferOffset = 0
    var encodingUniformBufferIndex = 0
    var encodingUniforms: UnsafeMutablePointer<EncodingUniform>

    var rotation: Float = 0

    var mesh: MTKMesh

    let layerRenderer: LayerRenderer
    // TODO(zhuowei): make this a real deque
    var metalTextureCache: CVMetalTextureCache!
    let mtlVertexDescriptor: MTLVertexDescriptor
    var videoFramePipelineState_YpCbCrBiPlanar: MTLRenderPipelineState!
    var videoFrameDepthPipelineState: MTLRenderPipelineState!
    var fullscreenQuadBuffer:MTLBuffer!
    var encodingGamma: Float = 1.0
    
    var drawPlanesWithInformedColors: Bool = false
    var fadeInOverlayAlpha: Float = 0.0
    var coolPulsingColorsTime: Float = 0.0
    var reprojectedFramesInARow: Int = 0
    var currentYuvTransform: simd_float4x4 = matrix_identity_float4x4
    
    // Was curious if it improved; it's still juddery.
    var useApplesReprojection = false
    
    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicUniformBuffer.label = "UniformBuffer"
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        let planeUniformBufferSize = alignedPlaneUniformSize * maxPlanesDrawn
        self.dynamicPlaneUniformBuffer = self.device.makeBuffer(length:planeUniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicPlaneUniformBuffer.label = "PlaneUniformBuffer"
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents()).bindMemory(to:PlaneUniform.self, capacity:1)
        
        let encodingUniformBufferSize = alignedEncodingUniformSize * maxBuffersInFlight
        self.dynamicEncodingUniformBuffer = self.device.makeBuffer(length:encodingUniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicEncodingUniformBuffer.label = "EncodingUniformBuffer"
        encodingUniforms = UnsafeMutableRawPointer(dynamicEncodingUniformBuffer.contents()).bindMemory(to:EncodingUniform.self, capacity:1)

        mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       layerRenderer: layerRenderer,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        let depthStateDescriptorAlways = MTLDepthStencilDescriptor()
        depthStateDescriptorAlways.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptorAlways.isDepthWriteEnabled = true
        self.depthStateAlways = device.makeDepthStencilState(descriptor:depthStateDescriptorAlways)!
        
        let depthStateDescriptorGreater = MTLDepthStencilDescriptor()
        depthStateDescriptorGreater.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptorGreater.isDepthWriteEnabled = true
        self.depthStateGreater = device.makeDepthStencilState(descriptor:depthStateDescriptorGreater)!

        do {
            mesh = try Renderer.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to build MetalKit Mesh. Error info: \(error)")
        }

        do {
            colorMap = try Renderer.loadTexture(device: device, textureName: "ColorMap")
        } catch {
            fatalError("Unable to load texture. Error info: \(error)")
        }
        
        if CVMetalTextureCacheCreate(nil, nil, self.device, nil, &metalTextureCache) != 0 {
            fatalError("CVMetalTextureCacheCreate")
        }
        fullscreenQuadVertices.withUnsafeBytes {
            fullscreenQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }
    
    func rebuildRenderPipelines() {
        guard let settings = Settings.getAlvrSettings() else {
            fatalError("streaming started: failed to retrieve alvr settings")
        }
            
        encodingGamma = settings.video.encoderConfig.encodingGamma
            
        let foveationVars = FFR.calculateFoveationVars(alvrEvent: EventHandler.shared.streamEvent!.STREAMING_STARTED, foveationSettings: settings.video.foveatedEncoding)
        videoFramePipelineState_YpCbCrBiPlanar = try! Renderer.buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            layerRenderer: layerRenderer,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            foveationVars: foveationVars,
                            variantName: "YpCbCrBiPlanar"
        )
    }
    
    func startRenderLoop() {
        Task {
            videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                    device: device,
                    layerRenderer: layerRenderer,
                    mtlVertexDescriptor: mtlVertexDescriptor
            )
            rebuildRenderPipelines()
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }

    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             layerRenderer: LayerRenderer,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Depth-only renderer, for correcting after overlay render just so Apple's compositor isn't annoying about it
    class func buildRenderPipelineForVideoFrameDepthWithDevice(device: MTLDevice,
                                                          layerRenderer: LayerRenderer,
                                                          mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
         
        let fragmentFunction = library?.makeFunction(name: "videoFrameDepthFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameDepthRenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    class func buildRenderPipelineForVideoFrameWithDevice(device: MTLDevice,
                                                          layerRenderer: LayerRenderer,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          foveationVars: FoveationVars,
                                                          variantName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
         
        let fragmentConstants = FFR.makeFunctionConstants(foveationVars)
        let fragmentFunction = try library?.makeFunction(name: "videoFrameFragmentShader_" + variantName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameRenderPipeline_" + variantName
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    class func buildMesh(device: MTLDevice,
                         mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
                                     segments: SIMD3<UInt32>(2, 2, 2),
                                     geometryType: MDLGeometryType.triangles,
                                     inwardNormals:false,
                                     allocator: metalAllocator)

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh:mdlMesh, device:device)
    }

    class func loadTexture(device: MTLDevice,
                           textureName: String) throws -> MTLTexture {
        /// Load texture data with optimal parameters for sampling

        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.generateMipmaps: NSNumber(value: true),
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
        ]

        return try textureLoader.newTexture(name: textureName,
                                            scaleFactor: 1.0,
                                            bundle: nil,
                                            options: textureLoaderOptions)

    }

    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
        
        encodingUniformBufferIndex = (encodingUniformBufferIndex + 1) % maxBuffersInFlight
        encodingUniformBufferOffset = alignedEncodingUniformSize * encodingUniformBufferIndex
        encodingUniforms = UnsafeMutableRawPointer(dynamicEncodingUniformBuffer.contents() + encodingUniformBufferOffset).bindMemory(to:EncodingUniform.self, capacity:1)
    }
    
    private func selectNextPlaneUniformBuffer() {
        /// Update the state of our uniform buffers before rendering

        planeUniformBufferIndex = (planeUniformBufferIndex + 1) % maxPlanesDrawn
        planeUniformBufferOffset = alignedPlaneUniformSize * planeUniformBufferIndex
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents() + planeUniformBufferOffset).bindMemory(to:PlaneUniform.self, capacity:1)
    }

    private func updateGameStateForVideoFrame(drawable: LayerRenderer.Drawable, framePose: simd_float4x4) {
        let simdDeviceAnchor = drawable.deviceAnchor != nil ? drawable.deviceAnchor!.originFromAnchorTransform : matrix_identity_float4x4
        
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            
            var framePoseNoTranslation = framePose
            var simdDeviceAnchorNoTranslation = simdDeviceAnchor
            framePoseNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            simdDeviceAnchorNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let viewMatrixFrame = (framePoseNoTranslation.inverse * simdDeviceAnchorNoTranslation).inverse
            let projection = ProjectiveTransform3D(leftTangent: Double(view.tangents[0]),
                                                   rightTangent: Double(view.tangents[1]),
                                                   topTangent: Double(view.tangents[2]),
                                                   bottomTangent: Double(view.tangents[3]),
                                                   nearZ: Double(drawable.depthRange.y),
                                                   farZ: Double(drawable.depthRange.x),
                                                   reverseZ: true)
            return Uniforms(projectionMatrix: .init(projection), modelViewMatrixFrame: viewMatrixFrame, modelViewMatrix: viewMatrix, tangents: view.tangents)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
    }

    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    func renderFrame() {
        /// Per frame updates hare
        EventHandler.shared.framesRendered += 1
        EventHandler.shared.totalFramesRendered += 1
        var streamingActiveForFrame = EventHandler.shared.streamingActive
        var isReprojected = false
        
        var queuedFrame:QueuedFrame? = nil
        
        guard let frame = layerRenderer.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }
        
        frame.startUpdate()
        frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        
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
        
        guard let drawable = frame.queryDrawable() else {
            if queuedFrame != nil {
                EventHandler.shared.lastQueuedFrame = queuedFrame
            }
            return
        }
        
        if queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp {
            alvr_report_compositor_start(queuedFrame!.timestamp)
        }

        if EventHandler.shared.alvrInitialized && streamingActiveForFrame {
            let ipd = drawable.views.count > 1 ? simd_length(drawable.views[0].transform.columns.3 - drawable.views[1].transform.columns.3) : 0.063
            if abs(EventHandler.shared.lastIpd - ipd) > 0.001 {
                print("Send view config")
                if EventHandler.shared.lastIpd != -1 {
                    print("IPD changed!", EventHandler.shared.lastIpd, "->", ipd)
                }
                else {
                    EventHandler.shared.framesRendered = 0
                    
                    let rebuildThread = Thread {
                        self.rebuildRenderPipelines()
                    }
                    rebuildThread.name = "Rebuild Render Pipelines Thread"
                    rebuildThread.start()
                }
                let leftAngles = atan(drawable.views[0].tangents)
                let rightAngles = drawable.views.count > 1 ? atan(drawable.views[1].tangents) : leftAngles
                let leftFov = AlvrFov(left: -leftAngles.x, right: leftAngles.y, up: leftAngles.z, down: -leftAngles.w)
                let rightFov = AlvrFov(left: -rightAngles.x, right: rightAngles.y, up: rightAngles.z, down: -rightAngles.w)
                EventHandler.shared.viewFovs = [leftFov, rightFov]
                EventHandler.shared.viewTransforms = [drawable.views[0].transform, drawable.views.count > 1 ? drawable.views[1].transform : drawable.views[0].transform]
                EventHandler.shared.lastIpd = ipd
            }
        }
        
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        EventHandler.shared.framesSinceLastDecode += 1
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        
        
        
        let vsyncTime = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        
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
            
            let targetTimestamp = vsyncTime + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            let realTargetTimestamp = vsyncTime + (Double(alvr_get_head_prediction_offset_ns()) / Double(NSEC_PER_SEC))
            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, realTargetTimestamp: realTargetTimestamp, delay: 0.0)
        }
        
        let deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)
        drawable.deviceAnchor = deviceAnchor
        
        /*if let queuedFrame = queuedFrame {
            let test_ts = queuedFrame.timestamp
            print("draw: \(test_ts)")
        }*/
        
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            if EventHandler.shared.alvrInitialized && queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame?.timestamp {
                let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                //print("Finished:", queuedFrame!.timestamp)
                alvr_report_submit(queuedFrame!.timestamp, vsyncTimeNs &- currentTimeNs)
                EventHandler.shared.lastSubmittedTimestamp = queuedFrame!.timestamp
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
            currentYuvTransform = VideoHandler.getYUVTransformForVideoFormat(videoFormat)
        }
        
        if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
            //print("render")
            renderStreamingFrame(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame, framePose: framePreviouslyPredictedPose ?? matrix_identity_float4x4)
            
            if isReprojected && useApplesReprojection {
                LayerRenderer.Clock().wait(until: drawable.frameTiming.renderingDeadline)
            }
            if isReprojected {
                reprojectedFramesInARow += 1
                if reprojectedFramesInARow > 90 {
                    fadeInOverlayAlpha += 0.02
                }
            }
            else {
                reprojectedFramesInARow = 0
                fadeInOverlayAlpha -= 0.02
            }
        }
        else
        {
            reprojectedFramesInARow = 0;

            let noFramePose = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)?.originFromAnchorTransform
            // TODO: draw a cool loading logo
            // TODO: maybe also show the room in wireframe or something cool here
            renderNothing(drawable: drawable, commandBuffer: commandBuffer, framePose: noFramePose ?? matrix_identity_float4x4)
            
            if EventHandler.shared.totalFramesRendered > 300 {
                fadeInOverlayAlpha += 0.02
            }
            
            renderOverlay(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame, framePose: noFramePose ?? matrix_identity_float4x4)
            renderStreamingFrameDepth(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame)
        }
        
        coolPulsingColorsTime += 0.005
        if coolPulsingColorsTime > 4.0 {
            coolPulsingColorsTime = 0.0
        }
        
        if fadeInOverlayAlpha > 1.0 {
            fadeInOverlayAlpha = 1.0
        }
        if fadeInOverlayAlpha < 0.0 {
            fadeInOverlayAlpha = 0.0
        }
        
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
        
        EventHandler.shared.lastQueuedFrame = queuedFrame
        EventHandler.shared.lastQueuedFramePose = framePreviouslyPredictedPose
    }
    
    func coolPulsingColor() -> simd_float4 {
        // Color picked from the ALVR logo
        let lightColor = simd_float4(0.05624, 0.73124, 0.75999, 1.0)
        let darkColor = simd_float4(0.01305, 0.26223, 0.63828, 1.0)
        var switchingFnT: Float = 0.0 // hold on light
        
        if coolPulsingColorsTime >= 1.0 && coolPulsingColorsTime < 2.0 {
            switchingFnT = coolPulsingColorsTime - 1.0 // light -> dark
        }
        else if coolPulsingColorsTime >= 2.0 && coolPulsingColorsTime < 3.0 {
            switchingFnT = 1.0 // hold on dark
        }
        else if coolPulsingColorsTime >= 3.0 && coolPulsingColorsTime < 4.0 {
            switchingFnT = coolPulsingColorsTime - 2.0 // dark -> light
        }

        var switchingFn = sin(switchingFnT * Float.pi * 0.5)
        if coolPulsingColorsTime >= 4.0 {
            switchingFn = 0.0
        }
        return simd_mix(lightColor, darkColor, simd_float4(repeating: switchingFn))
    }
    
    func planeToColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha = fadeInOverlayAlpha
        var subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        if drawPlanesWithInformedColors {
            switch(plane.classification) {
                case .ceiling: // #62ea80
                    return simd_float4(0.3843137254901961, 0.9176470588235294, 0.5019607843137255, 1.0) * subtleChange * planeAlpha
                case .door: // #1a5ff4
                    return simd_float4(0.10196078431372549, 0.37254901960784315, 0.9568627450980393, 1.0) * subtleChange * planeAlpha
                case .floor: // #bf6505
                    return simd_float4(0.7490196078431373, 0.396078431372549, 0.0196078431372549, 1.0) * subtleChange * planeAlpha
                case .seat: // #ef67af
                    return simd_float4(0.9372549019607843, 0.403921568627451, 0.6862745098039216, 1.0) * subtleChange * planeAlpha
                case .table: // #c937d3
                    return simd_float4(0.788235294117647, 0.21568627450980393, 0.8274509803921568, 1.0) * subtleChange * planeAlpha
                case .wall: // #dced5e
                    return simd_float4(0.8627450980392157, 0.9294117647058824, 0.3686274509803922, 1.0) * subtleChange * planeAlpha
                case .window: // #4aefce
                    return simd_float4(0.2901960784313726, 0.9372549019607843, 0.807843137254902, 1.0) * subtleChange * planeAlpha
                case .unknown: // #0e576b
                    return simd_float4(0.054901960784313725, 0.3411764705882353, 0.4196078431372549, 1.0) * subtleChange * planeAlpha
                case .undetermined: // #749606
                    return simd_float4(0.4549019607843137, 0.5882352941176471, 0.023529411764705882, 1.0) * subtleChange * planeAlpha
                default:
                    return simd_float4(1.0, 0.0, 0.0, 1.0) * subtleChange * planeAlpha // red
            }
        }
        else {
            if plane.classification == .ceiling {
                subtleChange *= 0.4
            }
            else if plane.classification == .wall {
                subtleChange *= 0.1
            }
            else if plane.classification == .floor {
                subtleChange *= 0.2
            }
            else if plane.classification == .seat {
                subtleChange *= 0.5
            }
            else {
                subtleChange = 0.01
            }
            return coolPulsingColor() * subtleChange * planeAlpha
        }
    }
    
    func planeToLineColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha = fadeInOverlayAlpha
        let subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        if drawPlanesWithInformedColors {
            return planeToColor(plane: plane)
        }
        else {
            return coolPulsingColor() * subtleChange * planeAlpha
        }
    }
    
    func renderStreamingFrameDepth(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, queuedFrame: QueuedFrame?) {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .dontCare
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.000000001
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Rerender depth"
        
        renderEncoder.pushDebugGroup("Draw ALVR Frame Depth")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(videoFrameDepthPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlways)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        renderEncoder.setFragmentBuffer(dynamicEncodingUniformBuffer, offset:encodingUniformBufferOffset, index: BufferIndex.encodingUniforms.rawValue) // unused
        
        let viewports = drawable.views.map { $0.textureMap.viewport }
        
        renderEncoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        guard let queuedFrame = queuedFrame else {
            renderEncoder.endEncoding()
            return
        }
        let pixelBuffer = queuedFrame.imageBuffer
        // https://cs.android.com/android/platform/superproject/main/+/main:external/webrtc/sdk/objc/components/renderer/metal/RTCMTLNV12Renderer.mm;l=108;drc=a81e9c82fc3fbc984f0f110407d1e44c9c01958a
        // TODO(zhuowei): yolo
        //TODO: prevailing wisdom on stackoverflow says that the CVMetalTextureRef has to be held until
        // rendering is complete, or the MtlTexture will be invalid?
        
        for i in 0...1 {
            var textureOut:CVMetalTexture! = nil
            var err:OSStatus = 0
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if i == 0 {
                err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, .r8Unorm,
                    width, height, 0, &textureOut);
            } else {
                err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, .rg8Unorm,
                    width/2, height/2, 1, &textureOut);
            }
            if err != 0 {
                fatalError("CVMetalTextureCacheCreateTextureFromImage \(err)")
            }
            guard let metalTexture = CVMetalTextureGetTexture(textureOut) else {
                fatalError("CVMetalTextureCacheCreateTextureFromImage")
            }
            renderEncoder.setFragmentTexture(metalTexture, index: i)
        }
        //let test = Unmanaged.passUnretained(pixelBuffer).toOpaque()
        //print("draw buf: \(test)")
        
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    func renderNothing(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, framePose: simd_float4x4) {
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Rendering Nothing"
        
        renderEncoder.pushDebugGroup("Draw Nothing")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(videoFrameDepthPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlways)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        renderEncoder.setFragmentBuffer(dynamicEncodingUniformBuffer, offset:encodingUniformBufferOffset, index: BufferIndex.encodingUniforms.rawValue) // unused
        
        let viewports = drawable.views.map { $0.textureMap.viewport }
        
        renderEncoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
    }
    
    func renderOverlay(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, queuedFrame: QueuedFrame?, framePose: simd_float4x4)
    {
        // Toss out the depth buffer, keep colors
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        let viewports = drawable.views.map { $0.textureMap.viewport }
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Plane Render Encoder"
        renderEncoder.pushDebugGroup("Draw planes")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        renderEncoder.setFragmentBuffer(dynamicEncodingUniformBuffer, offset:encodingUniformBufferOffset, index: BufferIndex.encodingUniforms.rawValue) // unused
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
        
        WorldTracker.shared.lockPlaneAnchors()
        
        // Render planes
        for plane in WorldTracker.shared.planeAnchors {
            let plane = plane.value
            let faces = plane.geometry.meshFaces
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
            
            //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeToColor(plane: plane)
            self.planeUniforms[0].planeDoProximity = 1.0
            renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            
            renderEncoder.setTriangleFillMode(.fill)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }
        
        // Render lines
        for plane in WorldTracker.shared.planeAnchors {
            let plane = plane.value
            let faces = plane.geometry.meshFaces
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
            
            //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeToLineColor(plane: plane)
            self.planeUniforms[0].planeDoProximity = 0.0
            renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            
            renderEncoder.setTriangleFillMode(.lines)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }
        WorldTracker.shared.unlockPlaneAnchors()
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    func renderStreamingFrame(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, queuedFrame: QueuedFrame?, framePose: simd_float4x4) {
        fadeInOverlayAlpha -= 0.01
        if fadeInOverlayAlpha < 0.0 {
            fadeInOverlayAlpha = 0.0
        }
    
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Primary Render Encoder"
        
        renderEncoder.pushDebugGroup("Draw ALVR Frames")
        
        renderEncoder.setCullMode(.back)
        
        renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setRenderPipelineState(videoFramePipelineState_YpCbCrBiPlanar)
        
        renderEncoder.setDepthStencilState(depthStateAlways)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        
        self.encodingUniforms[0].yuvTransform = currentYuvTransform
        self.encodingUniforms[0].encodingGamma = encodingGamma
        renderEncoder.setFragmentBuffer(dynamicEncodingUniformBuffer, offset:encodingUniformBufferOffset, index: BufferIndex.encodingUniforms.rawValue)
        
        let viewports = drawable.views.map { $0.textureMap.viewport }
        
        renderEncoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        guard let queuedFrame = queuedFrame else {
            renderEncoder.endEncoding()
            return
        }
        let pixelBuffer = queuedFrame.imageBuffer
        // https://cs.android.com/android/platform/superproject/main/+/main:external/webrtc/sdk/objc/components/renderer/metal/RTCMTLNV12Renderer.mm;l=108;drc=a81e9c82fc3fbc984f0f110407d1e44c9c01958a
        // TODO(zhuowei): yolo
        //TODO: prevailing wisdom on stackoverflow says that the CVMetalTextureRef has to be held until
        // rendering is complete, or the MtlTexture will be invalid?
        
        let textureTypes = VideoHandler.getTextureTypesForFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))
        for i in 0...1 {
            var textureOut:CVMetalTexture! = nil
            var err:OSStatus = 0
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if i == 0 {
                err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, textureTypes[i],
                    width, height, 0, &textureOut);
            } else {
                err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, textureTypes[i],
                    width/2, height/2, 1, &textureOut);
            }
            if err != 0 {
                fatalError("CVMetalTextureCacheCreateTextureFromImage \(err)")
            }
            guard let metalTexture = CVMetalTextureGetTexture(textureOut) else {
                fatalError("CVMetalTextureCacheCreateTextureFromImage")
            }
            renderEncoder.setFragmentTexture(metalTexture, index: i)
        }
        
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
        
        if fadeInOverlayAlpha > 0.0 {
            let fullViewPose = drawable.deviceAnchor != nil ? drawable.deviceAnchor!.originFromAnchorTransform : framePose
            // Not super kosher--we need the depth to be correct for the video frame box, but we can't have the view
            // outside of the video frame box be 0.0 depth or it won't get rastered by the compositor at all.
            // So we re-render the frame depth.
            renderOverlay(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame, framePose: framePose)
            renderStreamingFrameDepth(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame)
        }
    }
    
    func renderLoop() {
    
        layerRenderer.waitUntilRunning()
        
        EventHandler.shared.handleHeadsetRemovedOrReentry()
        let timeSinceLastLoop = CACurrentMediaTime()
        while EventHandler.shared.renderStarted {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                //EventHandler.shared.stop()
                EventHandler.shared.handleHeadsetRemovedOrReentry()
                EventHandler.shared.handleHeadsetRemoved()
                WorldTracker.shared.resetPlayspace()
                alvr_pause()

                // visionOS sometimes sends these invalidated things really fkn late...
                // But generally, we want to exit fully when the user exits.
                if CACurrentMediaTime() - timeSinceLastLoop < 1.0 {
                    exit(0)
                }
                break
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                //EventHandler.shared.handleHeadsetRemovedOrReentry()
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}
