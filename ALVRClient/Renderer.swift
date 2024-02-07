//
//  Renderer.swift
//
#if os(visionOS)
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

let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

// TODO(zhuowei): what's the z supposed to be?
// x, y, z
// u, v
let fullscreenQuadVertices:[Float] = [-1, -1, 0.1,
                                       1, -1, 0.1,
                                       -1, 1, 0.1,
                                       1, 1, 0.1,
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

class Renderer {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var colorMap: MTLTexture

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<UniformsArray>

    var rotation: Float = 0

    var mesh: MTKMesh

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    
    var alvrInitialized = false
    
    // TODO(zhuowei): does this need to be atomic?
    var inputRunning = false
    var vtDecompressionSession:VTDecompressionSession? = nil
    var videoFormat:CMFormatDescription? = nil
    var frameQueueLock = NSObject()
    struct QueuedFrame {
        let imageBuffer: CVImageBuffer
        let timestamp: UInt64
    }
    
    // TODO(zhuowei): make this a real deque
    var frameQueue = [QueuedFrame]()
    var frameQueueLastTimestamp: UInt64 = 0
    var frameQueueLastImageBuffer: CVImageBuffer? = nil
    var lastQueuedFrame: QueuedFrame? = nil
    var streamingActive = false
    
    var deviceAnchorsLock = NSObject()
    var deviceAnchorsQueue = [UInt64]()
    var deviceAnchorsDictionary = [UInt64: simd_float4x4]()
    var metalTextureCache: CVMetalTextureCache!
    var videoFramePipelineState:MTLRenderPipelineState
    var fullscreenQuadBuffer:MTLBuffer!
    var lastIpd:Float = -1
    var framesRendered:Int = 0
    
    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       layerRenderer: layerRenderer,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
            videoFramePipelineState = try Renderer.buildRenderPipelineForVideoFrameWithDevice(device: device,
                                                                       layerRenderer: layerRenderer,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        // TODO(zhuowei): hax
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = false
        self.depthState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!

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
        
        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
        if CVMetalTextureCacheCreate(nil, nil, self.device, nil, &metalTextureCache) != 0 {
            fatalError("CVMetalTextureCacheCreate")
        }
        fullscreenQuadVertices.withUnsafeBytes {
            fullscreenQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
    }
    
    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }
            
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
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    class func buildRenderPipelineForVideoFrameWithDevice(device: MTLDevice,
                                             layerRenderer: LayerRenderer,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
        let fragmentFunction = library?.makeFunction(name: "videoFrameFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameRenderPipeline"
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
    }

    private func updateGameState(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) {
        /// Update any game state before rendering
        
        let rotationAxis = SIMD3<Float>(1, 1, 0)
        let modelRotationMatrix = matrix4x4_rotation(radians: rotation, axis: rotationAxis)
        let modelTranslationMatrix = matrix4x4_translation(0.0, 0.0, -8.0)
        let modelMatrix = modelTranslationMatrix * modelRotationMatrix
        
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let projection = ProjectiveTransform3D(leftTangent: Double(view.tangents[0]),
                                                   rightTangent: Double(view.tangents[1]),
                                                   topTangent: Double(view.tangents[2]),
                                                   bottomTangent: Double(view.tangents[3]),
                                                   nearZ: Double(drawable.depthRange.y),
                                                   farZ: Double(drawable.depthRange.x),
                                                   reverseZ: true)
            
            return Uniforms(projectionMatrix: .init(projection), modelViewMatrix: viewMatrix * modelMatrix)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
        
        rotation += 0.01
    }
    
    private func updateGameStateForVideoFrame(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) {
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            return Uniforms(projectionMatrix: matrix_identity_float4x4, modelViewMatrix: matrix_identity_float4x4)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
    }
    
    func handleAlvrEvents() {
        while inputRunning {
            var alvrEvent = AlvrEvent()
            let res = alvr_poll_event(&alvrEvent)
            if !res {
                usleep(1000)
                continue
            }
            switch UInt32(alvrEvent.tag) {
            case ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue:
                print("hud message updated")
                let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                alvr_hud_message(hudMessageBuffer.baseAddress)
                print(String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8)!)
                hudMessageBuffer.deallocate()
            case ALVR_EVENT_STREAMING_STARTED.rawValue:
                print("streaming started: \(alvrEvent.STREAMING_STARTED)")
                streamingActive = true
                alvr_request_idr()
            case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                print("streaming stopped")
                streamingActive = false
            case ALVR_EVENT_HAPTICS.rawValue:
                print("haptics: \(alvrEvent.HAPTICS)")
            case ALVR_EVENT_CREATE_DECODER.rawValue:
                print("create decoder: \(alvrEvent.CREATE_DECODER)")
                while true {
                    guard let (nal, timestamp) = VideoHandler.pollNal() else {
                        fatalError("create decoder: failed to poll nal?!")
                        break
                    }
                    print(nal.count, timestamp)
                    NSLog("%@", nal as NSData)
                    if (nal[3] == 0x01 && nal[4] & 0x1f == H264_NAL_TYPE_SPS) || (nal[2] == 0x01 && nal[3] & 0x1f == H264_NAL_TYPE_SPS) {
                        // here we go!
                        (vtDecompressionSession, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nal)
                        break
                    }
                }
            case ALVR_EVENT_FRAME_READY.rawValue:
                // print("frame ready")
                
                while true {
                    guard let (nal, timestamp) = VideoHandler.pollNal() else {
                        break
                    }
                    
                    if let vtDecompressionSession = vtDecompressionSession {
                        VideoHandler.feedVideoIntoDecoder(decompressionSession: vtDecompressionSession, nals: nal, timestamp: timestamp, videoFormat: videoFormat!) { [self] imageBuffer in
                            alvr_report_frame_decoded(timestamp)
                            guard let imageBuffer = imageBuffer else {
                                return
                            }
                            
                            //let imageBufferPtr = Unmanaged.passUnretained(imageBuffer).toOpaque()
                            //print("finish decode: \(timestamp), \(imageBufferPtr), \(nal_type)")
                            
                            objc_sync_enter(frameQueueLock)
                            if frameQueueLastTimestamp != timestamp
                            {
                                // TODO: For some reason, really low frame rates seem to decode the wrong image for a split second?
                                // But for whatever reason this is fine at high FPS.
                                // From what I've read online, the only way to know if an H264 frame has actually completed is if
                                // the next frame is starting, so keep this around for now just in case.
                                if frameQueueLastImageBuffer != nil {
                                    //frameQueue.append(QueuedFrame(imageBuffer: frameQueueLastImageBuffer!, timestamp: frameQueueLastTimestamp))
                                    frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp))
                                }
                                else {
                                    frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp))
                                }
                                if frameQueue.count > 2 {
                                    frameQueue.removeFirst()
                                }
                                
                                //print("queue: \(frameQueueLastTimestamp) -> \(timestamp), \(test)")
                                
                                frameQueueLastTimestamp = timestamp
                                frameQueueLastImageBuffer = imageBuffer
                            }
                            
                            // Pull the very last imageBuffer for a given timestamp
                            if frameQueueLastTimestamp == timestamp {
                                 frameQueueLastImageBuffer = imageBuffer
                            }
                            
                            objc_sync_exit(frameQueueLock)
                        }
                    } else {
                        alvr_report_frame_decoded(timestamp)
                        alvr_report_compositor_start(timestamp)
                        alvr_report_submit(timestamp, 0)
                    }
                }
                
                
            default:
                print("msg")
            }
        }
    }

    func renderFrame() {
        /// Per frame updates hare
        framesRendered += 1
        var streamingActiveForFrame = streamingActive
        
        var queuedFrame:QueuedFrame? = nil
        if streamingActiveForFrame {
            let startPollTime = CACurrentMediaTime()
            while true {
                objc_sync_enter(frameQueueLock)
                queuedFrame = frameQueue.count > 0 ? frameQueue.removeFirst() : nil
                objc_sync_exit(frameQueueLock)
                if queuedFrame != nil ||  CACurrentMediaTime() - startPollTime > 0.01 {
                    break
                }
                
                // Recycle old frame with old timestamp/anchor (visionOS doesn't do timewarp for us?)
                if lastQueuedFrame != nil {
                    queuedFrame = lastQueuedFrame
                    break
                }
                sched_yield()
            }
        }
        
        if queuedFrame == nil && streamingActiveForFrame {
            streamingActiveForFrame = false
        }
        
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        frame.startUpdate()
        
        frame.endUpdate()

        if queuedFrame != nil {
            alvr_report_compositor_start(queuedFrame!.timestamp)
        }
        
        let renderingStreaming = false && streamingActiveForFrame && queuedFrame != nil
        
        if !renderingStreaming {
            guard let timing = frame.predictTiming() else { return }
            LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        }
        
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }
        
        guard let drawable = frame.queryDrawable() else { return }
        
        
        if !alvrInitialized {
            alvrInitialized = true
            // TODO(zhuowei): ???
            let refreshRates:[Float] = [90, 60, 45]
            alvr_initialize(/*java_vm=*/nil, /*context=*/nil, UInt32(drawable.colorTextures[0].width), UInt32(drawable.colorTextures[0].height), refreshRates, Int32(refreshRates.count), /*external_decoder=*/ true)
            alvr_resume()
        }
        if !inputRunning {
            inputRunning = true
            let eventsThread = Thread {
                self.handleAlvrEvents()
            }
            eventsThread.name = "Events Thread"
            eventsThread.start()
        }
        
        
        if alvrInitialized && streamingActiveForFrame {
            let ipd = drawable.views.count > 1 ? simd_length(drawable.views[0].transform.columns.3 - drawable.views[1].transform.columns.3) : 0.063
            if abs(lastIpd - ipd) > 0.001 {
                lastIpd = ipd
                let leftAngles = atan(drawable.views[0].tangents)
                let rightAngles = drawable.views.count > 1 ? atan(drawable.views[1].tangents) : leftAngles
                let leftFov = AlvrFov(left: -leftAngles.x, right: leftAngles.y, up: leftAngles.z, down: -leftAngles.w)
                let rightFov = AlvrFov(left: -rightAngles.x, right: rightAngles.y, up: rightAngles.z, down: -rightAngles.w)
                let fovs = [leftFov, rightFov]
                alvr_send_views_config(fovs, ipd)
            }
        }
        
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        // HACK: get a newer frame if possible
        if queuedFrame != nil {
            if frameQueue.count > 0 && streamingActiveForFrame {
                while true {
                    objc_sync_enter(frameQueueLock)
                    queuedFrame = frameQueue.count > 0 ? frameQueue.removeFirst() : nil
                    objc_sync_exit(frameQueueLock)
                    if queuedFrame != nil {
                        break
                    }
                    sched_yield()
                }
            }
        }
        
        frame.startSubmission()
        
        if renderingStreaming && lookupDeviceAnchorFor(timestamp: queuedFrame!.timestamp) != nil {
            // TODO: maybe find some mutable pointer hax to just copy in the ground truth, instead of asking for a value in the past.
            let time = Double(queuedFrame!.timestamp) / Double(NSEC_PER_SEC)
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
            drawable.deviceAnchor = deviceAnchor
            
            //print("found anchor for frame!", deviceAnchorLoc, queuedFrame!.timestamp, deviceAnchor?.originFromAnchorTransform)
        }
        if drawable.deviceAnchor == nil {
            if renderingStreaming {
                print("missing anchor!!")
            }
            let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
            
            drawable.deviceAnchor = deviceAnchor
        }
        
        /*if let queuedFrame = queuedFrame {
            let test_ts = queuedFrame.timestamp
            print("draw: \(test_ts)")
        }*/
        
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
            if let queuedFrame = queuedFrame {
                if self.alvrInitialized {
                    alvr_report_submit(queuedFrame.timestamp, 0)
                }
            }
        }
        
        if streamingActiveForFrame {
            renderStreamingFrame(drawable: drawable, commandBuffer: commandBuffer, queuedFrame: queuedFrame)
        } else {
            renderLobby(drawable: drawable, commandBuffer: commandBuffer)
        }
        
        drawable.encodePresent(commandBuffer: commandBuffer)
        
        commandBuffer.commit()
        
        frame.endSubmission()
        
        if self.alvrInitialized {
            let targetTimestamp = CACurrentMediaTime() + Double(min(alvr_get_head_prediction_offset_ns(), Renderer.maxPrediction)) / Double(NSEC_PER_SEC)
            sendTracking(targetTimestamp: targetTimestamp)
        }
        
        lastQueuedFrame = queuedFrame
    }
    
    func renderLobby(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        self.updateDynamicBufferState()
        
        self.updateGameState(drawable: drawable, deviceAnchor: drawable.deviceAnchor)
        
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
        
        renderEncoder.pushDebugGroup("Draw Box")
        
        renderEncoder.setCullMode(.back)
        
        renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        renderEncoder.setDepthStencilState(depthState)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        let viewports = drawable.views.map { $0.textureMap.viewport }
        
        renderEncoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        
        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout else {
                return
            }
            
            if layout.stride != 0 {
                let buffer = mesh.vertexBuffers[index]
                renderEncoder.setVertexBuffer(buffer.buffer, offset:buffer.offset, index: index)
            }
        }
        
        renderEncoder.setFragmentTexture(colorMap, index: TextureIndex.color.rawValue)
        
        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
            
        }
        
        renderEncoder.popDebugGroup()
        
        renderEncoder.endEncoding()
    }
    
    func renderStreamingFrame(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, queuedFrame: QueuedFrame?) {
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(drawable: drawable, deviceAnchor: drawable.deviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.01
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Primary Render Encoder"
        
        renderEncoder.pushDebugGroup("Draw Box")
        
        renderEncoder.setCullMode(.back)
        
        renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setRenderPipelineState(videoFramePipelineState)
        
        renderEncoder.setDepthStencilState(depthState)
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
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
    
    func renderLoop() {
        layerRenderer.waitUntilRunning()
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                inputRunning = false
                exit(0)
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                // TODO(zhuowei): input thread?
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
    
    static let maxPrediction = 15 * NSEC_PER_MSEC
    static let deviceIdHead = alvr_path_string_to_id("/user/head")
    
    func sendTracking(targetTimestamp: Double) {
        //let targetTimestamp = CACurrentMediaTime() + Double(min(alvr_get_head_prediction_offset_ns(), Renderer.maxPrediction)) / Double(NSEC_PER_SEC)
        let targetTimestampNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: targetTimestamp) else {
            return
        }
        deviceAnchorsQueue.append(targetTimestampNS)
        if deviceAnchorsQueue.count > 1000 {
            let val = deviceAnchorsQueue.removeFirst()
            deviceAnchorsDictionary.removeValue(forKey: val)
        }
        deviceAnchorsDictionary[targetTimestampNS] = deviceAnchor.originFromAnchorTransform
        let orientation = simd_quaternion(deviceAnchor.originFromAnchorTransform)
        let position = deviceAnchor.originFromAnchorTransform.columns.3
        var trackingMotion = AlvrDeviceMotion(device_id: Renderer.deviceIdHead, orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z), linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0))
        alvr_send_tracking(targetTimestampNS, &trackingMotion, 1)
    }
    
    func lookupDeviceAnchorFor(timestamp: UInt64) -> simd_float4x4? {
        return deviceAnchorsDictionary[timestamp]
    }
}

// Generic matrix math utility functions
func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4.init(columns:(vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                         vector_float4(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                         vector_float4(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                         vector_float4(                  0,                   0,                   0, 1)))
}

func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns:(vector_float4(1, 0, 0, 0),
                                         vector_float4(0, 1, 0, 0),
                                         vector_float4(0, 0, 1, 0),
                                         vector_float4(translationX, translationY, translationZ, 1)))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}
#endif
