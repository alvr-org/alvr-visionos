//
//  Renderer.swift
//
// Primarily, stuff for the MetalClientSystem rendering, but portions are shared
// with RealityKitClientSystem
//
// Notable portions include:
// - Pipeline setup for different color formats and compiled Metal constants (rebuildRenderPipelines)
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

let maxBuffersInFlight = 6
let maxPlanesDrawn = 512

enum RendererError: Error {
    case badVertexDescriptor
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

let hudQuadVertices: [Float] = [
    -0.5, -0.5, 0.0,
     0.5, -0.5, 0.0,
    -0.5,  0.5, 0.0,
     0.5,  0.5, 0.0,
     0.0,  1.0,
     1.0,  1.0,
     0.0,  0.0,
     1.0,  0.0
]
                                       
let unitVectorXYZVertices:[Float] = [0.0, 0.0, 0.0,
                                       1.0, 0.0, 0.0,
                                       0.01,0.0,0.0,
                                       
                                       0.0, 0.0, 0.0,
                                       0.0, 1.0, 0.0,
                                       0.0,0.01,0.0,
                                       
                                       0.0, 0.0, 0.0,
                                       0.0, 0.0, 1.0,
                                       0.0,0.0,0.01,
                                       
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

func NonlinearToLinearRGB(_ color: simd_float3) -> simd_float3 {
    let DIV12: Float = 1.0 / 12.92;
    let DIV1: Float = 1.0 / 1.055;
    let THRESHOLD: Float = 0.04045;
    let GAMMA = simd_float3(repeating: 2.4);
        
    let condition = simd_float3(color.x < THRESHOLD ? 1.0 : 0.0, color.y < THRESHOLD ? 1.0 : 0.0, color.z < THRESHOLD ? 1.0 : 0.0);
    let lowValues = color * DIV12;
    let highValues = pow((color + 0.055) * DIV1, GAMMA);
    return condition * lowValues + (1.0 - condition) * highValues;
}

class Renderer {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var pipelineState: MTLRenderPipelineState
    var depthStateAlways: MTLDepthStencilState
    var depthStateGreater: MTLDepthStencilState

    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>
    
    var dynamicPlaneUniformBuffer: MTLBuffer
    var planeUniformBufferOffset = 0
    var planeUniformBufferIndex = 0
    var planeUniforms: UnsafeMutablePointer<PlaneUniform>

    let layerRenderer: LayerRenderer?
    var metalTextureCache: CVMetalTextureCache!
    let mtlVertexDescriptor: MTLVertexDescriptor
    let mtlVertexDescriptorNoUV: MTLVertexDescriptor
    var videoFramePipelineState_YpCbCrBiPlanar: MTLRenderPipelineState!
    var videoFramePipelineState_SecretYpCbCrFormats: MTLRenderPipelineState!
    var videoFrameDepthPipelineState: MTLRenderPipelineState!
    var fullscreenQuadBuffer:MTLBuffer!
    var unitVectorXYZBuffer:MTLBuffer!
    var hudPipelineState: MTLRenderPipelineState!
    var hudQuadBuffer: MTLBuffer!
    var depthStateAlwaysNoWrite: MTLDepthStencilState!
    var performanceHudRenderer: PerformanceHudRenderer?
    var encodingGamma: Float = 1.0
    var lastReconfigureTime: Double = 0.0
    
    var drawPlanesWithInformedColors: Bool = false
    var fadeInOverlayAlpha: Float = 0.0
    var coolPulsingColorsTime: Float = 0.0
    private let chaperoneSystem = ChaperoneSystem()
#if CHAPERONE_PROFILE
    private var chaperoneProfileAccumMs: Double = 0.0
    private var chaperoneProfileSamples: Int = 0
    private var chaperoneProfileLastLog: Double = 0.0
    private var chaperoneProfileWindow: [Double] = []
    private let chaperoneProfileWindowSize: Int = 120
#endif
    var reprojectedFramesInARow: Int = 0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    var currentYuvTransform: simd_float4x4 = matrix_identity_float4x4
    
    // Was curious if it improved; it's still juddery.
    var useApplesReprojection = false
    
    // More readable helper var than layerRenderer == nil
    var isRealityKit = false
    var hdrEnabled = false
    var currentRenderColorFormat = renderColorFormatSDR
    var currentDrawableRenderColorFormat = renderColorFormatDrawableSDR
    
    //
    // Chroma keying shader vars
    //
    var chromaKeyEnabled = false
    var chromaKeyColor = simd_float3(0.0, 1.0, 0.0); // green
    
    //chromaKeyLerpDistRange is used to decide the amount of color to be used from either foreground or background
    //if the current distance from pixel color to chromaKey is smaller then chromaKeyLerpDistRange.x we use background,
    //if the current distance from pixel color to chromaKey is bigger then chromaKeyLerpDistRange.y we use foreground,
    //else, we alpha blend them
    //playing with this variable will decide how much the foreground and background blend together
    var chromaKeyLerpDistRange = simd_float2(0.005, 0.1);
    
    init(_ layerRenderer: LayerRenderer?) {
        self.layerRenderer = layerRenderer
        if layerRenderer == nil {
            isRealityKit = true
        }
        else {
#if XCODE_BETA_26
            if #available(visionOS 26.0, *) {
                //self.layerRenderer?.renderQuality = .init(1.0)
            }
#endif
        }
        
        guard let settings = Settings.getAlvrSettings() else {
            fatalError("streaming started: failed to retrieve alvr settings")
        }

        encodingGamma = EventHandler.shared.encodingGamma
        hdrEnabled = EventHandler.shared.enableHdr
        if hdrEnabled {
            currentRenderColorFormat = renderColorFormatHDR
            currentDrawableRenderColorFormat = renderColorFormatDrawableHDR
        }
        else {
            currentRenderColorFormat = renderColorFormatSDR
            currentDrawableRenderColorFormat = renderColorFormatSDR
        }
        
        self.device = layerRenderer?.device ?? MTLCreateSystemDefaultDevice()!
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
        
        mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
        mtlVertexDescriptorNoUV = Renderer.buildMetalVertexDescriptorNoUV()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                       depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                       viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                       vertexShaderName: "vertexShader",
                                                                       fragmentShaderName: "fragmentShader")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        do {
            hudPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                          mtlVertexDescriptor: mtlVertexDescriptor,
                                                                          colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                          depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                          viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                          vertexShaderName: "hudVertexShader",
                                                                          fragmentShaderName: "hudFragmentShader")
        } catch {
            fatalError("Unable to compile HUD render pipeline state.  Error info: \(error)")
        }

        let depthStateDescriptorAlways = MTLDepthStencilDescriptor()
        depthStateDescriptorAlways.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptorAlways.isDepthWriteEnabled = true
        self.depthStateAlways = device.makeDepthStencilState(descriptor:depthStateDescriptorAlways)!
        let depthStateDescriptorAlwaysNoWrite = MTLDepthStencilDescriptor()
        depthStateDescriptorAlwaysNoWrite.depthCompareFunction = .always
        depthStateDescriptorAlwaysNoWrite.isDepthWriteEnabled = false
        self.depthStateAlwaysNoWrite = device.makeDepthStencilState(descriptor: depthStateDescriptorAlwaysNoWrite)!
        
        let depthStateDescriptorGreater = MTLDepthStencilDescriptor()
        depthStateDescriptorGreater.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptorGreater.isDepthWriteEnabled = true
        self.depthStateGreater = device.makeDepthStencilState(descriptor:depthStateDescriptorGreater)!
        
        if CVMetalTextureCacheCreate(nil, nil, self.device, nil, &metalTextureCache) != 0 {
            fatalError("CVMetalTextureCacheCreate")
        }
        fullscreenQuadVertices.withUnsafeBytes {
            fullscreenQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        hudQuadVertices.withUnsafeBytes {
            hudQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        unitVectorXYZVertices.withUnsafeBytes {
            unitVectorXYZBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        self.videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                device: self.device,
                mtlVertexDescriptor: self.mtlVertexDescriptor,
                colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                viewCount: layerRenderer?.properties.viewCount ?? renderViewCount
        )
        
        rebuildRenderPipelines()

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }
    
    func rebuildRenderPipelines() {
        guard let settings = Settings.getAlvrSettings() else {
            fatalError("streaming started: failed to retrieve alvr settings")
        }
        print("rebuildRenderPipelines")
            
        encodingGamma = EventHandler.shared.encodingGamma
        hdrEnabled = EventHandler.shared.enableHdr
        if hdrEnabled {
            currentRenderColorFormat = renderColorFormatHDR
            currentDrawableRenderColorFormat = renderColorFormatDrawableHDR
        }
        else {
            currentRenderColorFormat = renderColorFormatSDR
            currentDrawableRenderColorFormat = renderColorFormatSDR
        }
            
        let foveationVars = FFR.calculateFoveationVars(alvrEvent: EventHandler.shared.streamEvent!.STREAMING_STARTED, foveationSettings: settings.video.foveated_encoding)
        videoFramePipelineState_YpCbCrBiPlanar = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            variantName: "YpCbCrBiPlanar"
        )
        videoFramePipelineState_SecretYpCbCrFormats = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            variantName: "SecretYpCbCrFormats"
        )
        
        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                       depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                       viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                       vertexShaderName: "vertexShader",
                                                                       fragmentShaderName: "fragmentShader")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        
        self.videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                device: self.device,
                mtlVertexDescriptor: self.mtlVertexDescriptor,
                colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                viewCount: layerRenderer?.properties.viewCount ?? renderViewCount
        )
    }

    // Vertex descriptor with float3 position and float2 UVs
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
    
    // Vertex descriptor without any UV info
    class func buildMetalVertexDescriptorNoUV() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    // Generic render pipeline, used for the wireframe rendering.
    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             mtlVertexDescriptor: MTLVertexDescriptor,
                                             colorFormat: MTLPixelFormat,
                                             depthFormat: MTLPixelFormat,
                                             viewCount: Int,
                                             vertexShaderName: String,
                                             fragmentShaderName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: vertexShaderName)
        let fragmentFunction = library?.makeFunction(name: fragmentShaderName)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Copy/"passthrough" pipeline for transferring from an offscreen MTLTexture
    // to the final RealityKit MTLTexture.
    func buildCopyPipelineWithDevice(device: MTLDevice,
                                             colorFormat: MTLPixelFormat,
                                             viewCount: Int,
                                             vrrScreenSize: MTLSize?,
                                             vrrPhysSize: MTLSize?,
                                             vertexShaderName: String,
                                             fragmentShaderName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()
        
        let fragmentConstants = MTLFunctionConstantValues()
        let settings = ALVRClientApp.gStore.settings
        if #available(visionOS 2.0, *) {
            chromaKeyEnabled = settings.chromaKeyEnabled
        }
        else {
            chromaKeyEnabled = settings.chromaKeyEnabled && isRealityKit
        }
        chromaKeyColor = simd_float3(settings.chromaKeyColorR, settings.chromaKeyColorG, settings.chromaKeyColorB)
        chromaKeyLerpDistRange = simd_float2(settings.chromaKeyDistRangeMin, settings.chromaKeyDistRangeMax)

        var mutVrrScreenSize = simd_float2(Float(vrrScreenSize?.width ?? 1), Float(vrrScreenSize?.height ?? 1))
        var mutVrrPhysSize = simd_float2(Float(vrrPhysSize?.width ?? 1), Float(vrrPhysSize?.height ?? 1))
        var chromaKeyColorLinear = NonlinearToLinearRGB(chromaKeyColor)
        fragmentConstants.setConstantValue(&chromaKeyEnabled, type: .bool, index: ALVRFunctionConstant.chromaKeyEnabled.rawValue)
        fragmentConstants.setConstantValue(&chromaKeyColorLinear, type: .float3, index: ALVRFunctionConstant.chromaKeyColor.rawValue)
        fragmentConstants.setConstantValue(&chromaKeyLerpDistRange, type: .float2, index: ALVRFunctionConstant.chromaKeyLerpDistRange.rawValue)
        fragmentConstants.setConstantValue(&isRealityKit, type: .bool, index: ALVRFunctionConstant.realityKitEnabled.rawValue)
        fragmentConstants.setConstantValue(&mutVrrScreenSize, type: .float2, index: ALVRFunctionConstant.vrrScreenSize.rawValue)
        fragmentConstants.setConstantValue(&mutVrrPhysSize, type: .float2, index: ALVRFunctionConstant.vrrPhysSize.rawValue)

        let vertexFunction = try! library?.makeFunction(name: vertexShaderName, constantValues: fragmentConstants)
        let fragmentFunction = try! library?.makeFunction(name: fragmentShaderName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptorNoUV

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Depth-only renderer, for correcting after overlay render just so Apple's compositor isn't annoying about it
    class func buildRenderPipelineForVideoFrameDepthWithDevice(device: MTLDevice,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          colorFormat: MTLPixelFormat,
                                                          depthFormat: MTLPixelFormat,
                                                          viewCount: Int) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
        let fragmentFunction = library?.makeFunction(name: "videoFrameDepthFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameDepthRenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        //pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Video frame renderer, incl my own YCbCr stage and/or Apple's 48 private YCbCr texture formats.
    func buildRenderPipelineForVideoFrameWithDevice(device: MTLDevice,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          colorFormat: MTLPixelFormat,
                                                          viewCount: Int,
                                                          foveationVars: FoveationVars,
                                                          variantName: String) throws -> MTLRenderPipelineState {
        

        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
        let fragmentConstants = FFR.makeFunctionConstants(foveationVars)
        
        let settings = ALVRClientApp.gStore.settings
        if #available(visionOS 2.0, *) {
            chromaKeyEnabled = settings.chromaKeyEnabled
        }
        else {
            chromaKeyEnabled = settings.chromaKeyEnabled && isRealityKit
        }
        chromaKeyColor = simd_float3(settings.chromaKeyColorR, settings.chromaKeyColorG, settings.chromaKeyColorB)
        chromaKeyLerpDistRange = simd_float2(settings.chromaKeyDistRangeMin, settings.chromaKeyDistRangeMax)

        var chromaKeyColorLinear = NonlinearToLinearRGB(chromaKeyColor)
        fragmentConstants.setConstantValue(&chromaKeyEnabled, type: .bool, index: ALVRFunctionConstant.chromaKeyEnabled.rawValue)
        fragmentConstants.setConstantValue(&chromaKeyColorLinear, type: .float3, index: ALVRFunctionConstant.chromaKeyColor.rawValue)
        fragmentConstants.setConstantValue(&chromaKeyLerpDistRange, type: .float2, index: ALVRFunctionConstant.chromaKeyLerpDistRange.rawValue)
        fragmentConstants.setConstantValue(&isRealityKit, type: .bool, index: ALVRFunctionConstant.realityKitEnabled.rawValue)
        fragmentConstants.setConstantValue(&encodingGamma, type: .float, index: ALVRFunctionConstant.encodingGamma.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.0, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform0.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.1, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform1.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.2, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform2.rawValue)
        fragmentConstants.setConstantValue(&currentYuvTransform.columns.3, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform3.rawValue)
        
        let fragmentFunction = try library?.makeFunction(name: "videoFrameFragmentShader_" + variantName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameRenderPipeline_" + variantName
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        //pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // Advances the uniform buffer for the next frame, values can be written to `uniforms`
    // after this is called.
    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }
    
    // Advances the Plane uniform buffer, values can be written to `planeUniforms`
    // after this is called.
    private func selectNextPlaneUniformBuffer() {
        /// Update the state of our uniform buffers before rendering

        planeUniformBufferIndex = (planeUniformBufferIndex + 1) % maxPlanesDrawn
        planeUniformBufferOffset = alignedPlaneUniformSize * planeUniformBufferIndex
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents() + planeUniformBufferOffset).bindMemory(to:PlaneUniform.self, capacity:1)
    }

    // Writes FOV/tangents/etc information to the uniform buffer.
    private func updateGameStateForVideoFrame(_ whichIdx: Int, drawable: LayerRenderer.Drawable?, viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        let settings = ALVRClientApp.gStore.settings
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let realTangents = realViewTangents[viewIndex]
            let sentTangents = sentViewTangents[viewIndex]
            
            var framePoseNoTranslation = framePose
            var simdDeviceAnchorNoTranslation = simdDeviceAnchor
            framePoseNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            simdDeviceAnchorNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            let viewMatrix = (simdDeviceAnchor * viewTransforms[viewIndex]).inverse
            let viewMatrixFrame = (framePoseNoTranslation.inverse * simdDeviceAnchorNoTranslation * viewTransforms[viewIndex]).inverse
            let viewMatrixFrameRk = (framePoseNoTranslation.inverse * simdDeviceAnchorNoTranslation).inverse // RealityKit implicitly applies the view transforms when we draw the quad entity
            var projection = matrix_identity_float4x4
            if #available(visionOS 2.0, *), drawable != nil {
#if XCODE_BETA_16
                projection = drawable!.computeProjection(viewIndex: viewIndex)
#else
                let p = ProjectiveTransform3D(leftTangent: Double(realTangents[0]),
                          rightTangent: Double(realTangents[1]),
                          topTangent: Double(realTangents[2]),
                          bottomTangent: Double(realTangents[3]),
                          nearZ: nearZ,
                          farZ: farZ,
                          reverseZ: true)
                projection = matrix_float4x4(p)
#endif
            }
            else {
                let p = ProjectiveTransform3D(leftTangent: Double(realTangents[0]),
                          rightTangent: Double(realTangents[1]),
                          topTangent: Double(realTangents[2]),
                          bottomTangent: Double(realTangents[3]),
                          nearZ: nearZ,
                          farZ: farZ,
                          reverseZ: true)
                projection = matrix_float4x4(p)
            }
            return Uniforms(projectionMatrix: projection, modelViewMatrixFrame: isRealityKit ? viewMatrixFrameRk : viewMatrixFrame, modelViewMatrix: viewMatrix, tangents: sentTangents)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if viewTransforms.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
    }
    
    // Checks if eye tracking was secretly added, maybe, hard to know really.
    func checkEyes(drawable: LayerRenderer.Drawable) {
        print("begin -----")
        print(drawable.colorTextures.first?.width as Any, drawable.colorTextures.first?.height as Any)
        //print(drawable.views[0].transform - EventHandler.shared.viewTransforms[0])
        //print(drawable.views[1].transform - EventHandler.shared.viewTransforms[1])
        if let vrr = drawable.rasterizationRateMaps.first {
            let eyeCenterX = Float(vrr.screenSize.width) / 2.0
            let eyeCenterY = Float(vrr.screenSize.height) / 2.0
            let physSizeL = vrr.physicalSize(layer: 0)
            let physCoordsL = vrr.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: eyeCenterX, y: eyeCenterY), layer: 0)
            
            let physSizeR = vrr.physicalSize(layer: 1)
            let physCoordsR = vrr.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: eyeCenterX, y: eyeCenterY), layer: 1)
            
            print(physSizeL, physSizeR, vrr.screenSize.width, vrr.screenSize.height, ":::", Float(physCoordsL.x) / Float(physSizeL.width), Float(physCoordsL.y) / Float(physSizeL.height), ":::", Float(physCoordsR.x) / Float(physSizeR.width), Float(physCoordsR.y) / Float(physSizeR.height))
        }
        
        print("end -------")
    }
    
    // Adjust view transforms for debugging various issues.
    func fixTransform(_ transform: simd_float4x4) -> simd_float4x4 {
        //var out = matrix_identity_float4x4
        //out.columns.3 = transform.columns.3
        //out.columns.3.w = 1.0
        return transform.translationOnly() // TODO: undo this when we fix canted views in 20.15
    }
    
    // Adjusts view tangents for debugging various issues.
    func fixTangents(_ tangents: simd_float4) -> simd_float4 {
        return tangents
    }
    
    func renderToDrawable(_ drawable: LayerRenderer.Drawable) {
        
    }

    // Render the frame, only used in MetalClientSystem renderer.
    func renderFrame() {
        /// Per frame updates hare
        EventHandler.shared.framesRendered += 1
        EventHandler.shared.totalFramesRendered += 1
        var streamingActiveForFrame = EventHandler.shared.streamingActive
        var isReprojected = false
        
        var queuedFrame:QueuedFrame? = nil
        
        guard let frame = layerRenderer!.queryNextFrame() else { return }
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

#if XCODE_BETA_26
        // MTLSize(width: 4338, height: 3478, depth: 1) MTLSize(width: 1888, height: 1792, depth: 1) by default
        // MTLSize(width: 6262, height: 5020, depth: 1) MTLSize(width: 2496, height: 2432, depth: 1) at 1.0 render quality
        var mainDrawable = LayerRenderer.Drawable()
        var drawables: [LayerRenderer.Drawable] = []
        if #available(visionOS 26.0, *) {
            drawables = frame.queryDrawables()
            if drawables.isEmpty {
                if queuedFrame != nil {
                    EventHandler.shared.lastQueuedFrame = queuedFrame
                }
                return
            }
            mainDrawable = drawables[0]
            //print(drawable.rasterizationRateMaps[0].screenSize, drawable.rasterizationRateMaps[0].physicalSize(layer: 0))
        }
        else {
            guard let _drawable = frame.queryDrawable() else {
                if queuedFrame != nil {
                    EventHandler.shared.lastQueuedFrame = queuedFrame
                }
                return
            }
            mainDrawable = _drawable
            drawables = [_drawable]
        }
#else
        guard let _drawable = frame.queryDrawable() else {
            if queuedFrame != nil {
                EventHandler.shared.lastQueuedFrame = queuedFrame
            }
            return
        }
        var mainDrawable = _drawable
        var drawables: [LayerRenderer.Drawable] = [_drawable]
#endif
        
        let nalViewsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { nalViewsPtr.deallocate() }
        
        if queuedFrame != nil && !queuedFrame!.viewParamsValid /*&& EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp*/ {
            alvr_report_compositor_start(queuedFrame!.timestamp, nalViewsPtr)
            queuedFrame = QueuedFrame(imageBuffer: queuedFrame!.imageBuffer, timestamp: queuedFrame!.timestamp, viewParamsValid: true, viewParams: [nalViewsPtr[0], nalViewsPtr[1]])
        }

        if EventHandler.shared.alvrInitialized && streamingActiveForFrame {
            let settings = ALVRClientApp.gStore.settings
            var ipd = mainDrawable.views.count > 1 ? simd_length(mainDrawable.views[0].transform.columns.3 - mainDrawable.views[1].transform.columns.3) : 0.063
#if targetEnvironment(simulator)
            ipd = 0.063
            print(EventHandler.shared.lastIpd)
#endif
            if abs(EventHandler.shared.lastIpd - ipd) > 0.001 {
                print("Send view config")
                
                if EventHandler.shared.lastIpd != -1 {
                    print("IPD changed!", EventHandler.shared.lastIpd, "->", ipd)
                }
                else {
                    print("IPD is", ipd)
                    EventHandler.shared.framesRendered = 0
                    lastReconfigureTime = CACurrentMediaTime()
                    
                    let rebuildThread = Thread {
                        self.rebuildRenderPipelines()
                    }
                    rebuildThread.name = "Rebuild Render Pipelines Thread"
                    rebuildThread.start()
                }
                
                // TODO: Fix tangents to fill entire FoV if canting ever becomes more intense like PFD was
                let tangentsLeft = mainDrawable.gimmeTangents(viewIndex: 0)
                let tangentsRight = mainDrawable.gimmeTangents(viewIndex: 1)
                let transformLeft = mainDrawable.views[0].transform
                let transformRight = mainDrawable.views[1].transform
                let leftAngles = atan(tangentsLeft * settings.fovRenderScale)
                let rightAngles = mainDrawable.views.count > 1 ? atan(tangentsRight * settings.fovRenderScale) : leftAngles
                let leftFov = AlvrFov(left: -leftAngles.x, right: leftAngles.y, up: leftAngles.z, down: -leftAngles.w)
                let rightFov = AlvrFov(left: -rightAngles.x, right: rightAngles.y, up: rightAngles.z, down: -rightAngles.w)
                
                let (leftFovCorrected, tangentsLeftCorrected, transformLeftCorrected) = mainDrawable._cantedViewToProportionalCircumscribedOrthogonal(fov: leftFov, viewTransform: transformLeft, fovPostScale: 1.0)
                let (rightFovCorrected, tangentsRightCorrected, transformRightCorrected) = mainDrawable._cantedViewToProportionalCircumscribedOrthogonal(fov: rightFov, viewTransform: transformRight, fovPostScale: 1.0)
                
                EventHandler.shared.viewFovs = [leftFovCorrected, rightFovCorrected]
                EventHandler.shared.viewTransforms = [fixTransform(transformLeftCorrected), mainDrawable.views.count > 1 ? fixTransform(transformRightCorrected) : fixTransform(transformLeftCorrected)]
                EventHandler.shared.lastIpd = ipd
                
                // Wait, is this correct?
                if mainDrawable.views.count > 1 {
                    EventHandler.shared.sentViewTangents = [tangentsLeftCorrected, tangentsRightCorrected]
                    EventHandler.shared.realViewTangents = [tangentsLeft, tangentsRight]
                }
                else {
                    EventHandler.shared.sentViewTangents = [tangentsLeftCorrected, tangentsRightCorrected]
                    EventHandler.shared.realViewTangents = [tangentsLeft, tangentsLeft]
                }
                
                
                WorldTracker.shared.sendViewParams(viewTransforms:  EventHandler.shared.viewTransforms, viewFovs: EventHandler.shared.viewFovs)
            }
            
            var needsPipelineRebuild = false
            if EventHandler.shared.encodingGamma != encodingGamma {
                needsPipelineRebuild = true
            }
            
            if CACurrentMediaTime() - lastReconfigureTime > 1.0 && (settings.chromaKeyEnabled != chromaKeyEnabled || settings.chromaKeyColorR != chromaKeyColor.x || settings.chromaKeyColorG != chromaKeyColor.y || settings.chromaKeyColorB != chromaKeyColor.z || settings.chromaKeyDistRangeMin != chromaKeyLerpDistRange.x || settings.chromaKeyDistRangeMax != chromaKeyLerpDistRange.y) {
                lastReconfigureTime = CACurrentMediaTime()
                needsPipelineRebuild = true
            }
            
            if let videoFormat = EventHandler.shared.videoFormat {
                let nextYuvTransform = VideoHandler.getYUVTransformForVideoFormat(videoFormat)
                if nextYuvTransform != currentYuvTransform {
                    needsPipelineRebuild = true
                }
                currentYuvTransform = nextYuvTransform
            }
            
            if needsPipelineRebuild {
                lastReconfigureTime = CACurrentMediaTime()
                let rebuildThread = Thread {
                    self.rebuildRenderPipelines()
                }
                rebuildThread.name = "Rebuild Render Pipelines Thread"
                rebuildThread.start()
            }
        }
        
        //checkEyes(drawable: mainDrawable)
        
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        EventHandler.shared.framesSinceLastDecode += 1
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        
        if queuedFrame != nil && !queuedFrame!.viewParamsValid {
            print("aaaaaaaa bad view params")
        }
        
        let vsyncTime = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.presentationTime).timeInterval
        let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        if ALVRClientApp.gStore.settings.showPerformanceHud {
            PerformanceTracker.shared.recordFramePresentation(presentationTime: mainDrawable.frameTiming.presentationTime, timestampNs: queuedFrame?.timestamp)
            PerformanceTracker.shared.logIfNeeded(presentationTime: mainDrawable.frameTiming.presentationTime)
        }
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if EventHandler.shared.alvrInitialized && EventHandler.shared.lastIpd != -1 {
            if #available(visionOS 2.0, *) {
                EventHandler.shared.viewTransforms = [fixTransform(mainDrawable.views[0].transform), mainDrawable.views.count > 1 ? fixTransform(mainDrawable.views[1].transform) : fixTransform(mainDrawable.views[0].transform)]
            }
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms
            
            let targetTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))//LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval
            
            if !ALVRClientApp.gStore.settings.targetHandsAtRoundtripLatency {
                if #available(visionOS 2.0, *) {
                    anchorTimestamp = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval
                }
                else {
                    anchorTimestamp = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.renderingDeadline).timeInterval
                }
            }
            
            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)
        }
        
        let deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)
        
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            if EventHandler.shared.alvrInitialized && queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame?.timestamp {
                let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                
                //let currentTimeNs = UInt64(commandBuffer.gpuEndTime * Double(NSEC_PER_SEC))
                //let actualRenderTimeNs = UInt64((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * Double(NSEC_PER_SEC))
                //print((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0)
                
                //print("Finished:", queuedFrame!.timestamp)
                alvr_report_submit(queuedFrame!.timestamp, vsyncTimeNs &- currentTimeNs)
                EventHandler.shared.lastSubmittedTimestamp = queuedFrame!.timestamp
            }
            if ALVRClientApp.gStore.settings.showPerformanceHud, let ts = queuedFrame?.timestamp {
                PerformanceTracker.shared.recordSubmit(timestampNs: ts)
                PerformanceTracker.shared.recordGpu(timestampNs: ts, gpuStartTime: commandBuffer.gpuStartTime, gpuEndTime: commandBuffer.gpuEndTime)
            }
        }

        // List of reasons to not display a frame
        var frameIsSuitableForDisplaying = true
        //print(EventHandler.shared.lastIpd, WorldTracker.shared.worldTrackingAddedOriginAnchor, EventHandler.shared.framesRendered)
        if EventHandler.shared.lastIpd == -1 || EventHandler.shared.framesRendered < 90 {
            // Don't show frame if we haven't sent the view config and received frames
            // with that config applied.
            frameIsSuitableForDisplaying = false
            print("IPD is bad, no frame", EventHandler.shared.framesRendered)
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
        
        if !(renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil) {
            // Things to do once if no frame is rendering (show the wireframe)
            if EventHandler.shared.totalFramesRendered > 300 {
                fadeInOverlayAlpha += 0.02
            }
        }
        else {
            // Things to do if a frame is rendering (fade wireframe, or show wireframe is reprojection is too long)
            fadeInOverlayAlpha -= 0.01
            if fadeInOverlayAlpha < 0.0 {
                fadeInOverlayAlpha = 0.0
            }
            
            if isReprojected && useApplesReprojection {
                LayerRenderer.Clock().wait(until: mainDrawable.frameTiming.renderingDeadline)
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

        
        if ALVRClientApp.gStore.settings.showPerformanceHud,
           renderingStreaming,
           frameIsSuitableForDisplaying,
           let queuedFrame {
            PerformanceTracker.shared.recordCompositorStart(timestampNs: queuedFrame.timestamp)
        }
        for drawable in drawables {
            drawable.deviceAnchor = deviceAnchor
            
            // TODO: check layerRenderer.configuration.layout == .layered ?
            let viewports = drawable.views.map { $0.textureMap.viewport }
            let rasterizationRateMap = drawable.rasterizationRateMaps.first
            let viewTransforms = drawable.views.map { $0.transform }
            let sentViewTangents = drawable.views.enumerated().map { (idx, v) in EventHandler.shared.sentViewTangents[idx] }
            let realViewTangents = drawable.views.enumerated().map { (idx, v) in EventHandler.shared.realViewTangents[idx] }
            let nearZ =  Double(drawable.depthRange.y)
            let farZ = Double(drawable.depthRange.x)
            let simdDeviceAnchor = WorldTracker.shared.floorCorrectionTransform.asFloat4x4() * (deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4)
            let framePose = framePreviouslyPredictedPose ?? matrix_identity_float4x4
            
#if DEBUG_ALVR_TRACKING
            WorldTracker.shared.lockDebuggables()
            
            let headDebug = (simdDeviceAnchor.columns.3.asFloat3() - simdDeviceAnchor.columns.2.asFloat3()).asFloat4x4() * simdDeviceAnchor.orientationOnly().asFloat4x4()
            WorldTracker.shared.addDebuggablePose(headDebug, 0.1)
            
            for transform in viewTransforms {
                let mat = headDebug * transform
                WorldTracker.shared.addDebuggablePose(mat, 0.05)
            }
            
            WorldTracker.shared.unlockDebuggables()
#endif
            
            if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
                //print("render")
                if let encoder = beginRenderStreamingFrame(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable) {
                    renderStreamingFrame(0, commandBuffer: commandBuffer, renderEncoder: encoder, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
                    endRenderStreamingFrame(renderEncoder: encoder)
                }
                renderStreamingFrameOverlays(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable)
            }
            else
            {
                reprojectedFramesInARow = 0;

                let noFramePose = simdDeviceAnchor
                // TODO: draw a cool loading logo
                renderNothing(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable)
                
                renderOverlay(commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor)
                if !isRealityKit {
                    renderStreamingFrameDepth(commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame)
                }
            }
            
            drawable.encodePresent(commandBuffer: commandBuffer)
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
        
        commandBuffer.commit()
        frame.endSubmission()
        
        EventHandler.shared.lastQueuedFrame = queuedFrame
        EventHandler.shared.lastQueuedFramePose = framePreviouslyPredictedPose
    }
    
    // Pulse the wireframe between cyan and blue.
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
    
    // Can draw planes with debug colors, or with a subtle transparency change based on the type.
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
    
    // Line color for a given ARKit Plane
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
    
    // Only renders the frame depth, used to correct depth after the overlay is rendered
    // because Apple's Metal renderer is kinda weird about it.
    func renderStreamingFrameDepth(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .dontCare
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: chromaKeyEnabled ? 0.0 : 1.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.000000001
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
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
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // Clears the render target, nothing more nothing less.
    func renderNothing(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = isRealityKit ? (whichIdx == 0 ? .clear : .load) : .clear 
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        
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
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
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
    
    // Renders a wireframe overlay on top of the existing video frame (or nothing)
    func renderOverlay(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4],  nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4)
    {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
        // Toss out the depth buffer, keep colors
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
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
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif

        WorldTracker.shared.lockPlaneAnchors()
        
        var firstBind = true
        if fadeInOverlayAlpha > 0.0 {
            // Render planes
            for planeEntry in WorldTracker.shared.planeAnchors {
                let plane = planeEntry.value
                let faces = plane.geometry.meshFaces
                
                // VRR can't do lines
                if faces.primitive != GeometryElement.Primitive.triangle {
                    continue
                }
                
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
                
                //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
                self.planeUniforms[0].planeColor = planeToColor(plane: plane)
                self.planeUniforms[0].planeDoProximity = 1.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.fill)
                renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                    indexCount: faces.count*3,
                                                    indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                    indexBuffer: faces.buffer,
                                                    indexBufferOffset: 0)
            }
            
            // Render lines
            for planeEntry in WorldTracker.shared.planeAnchors {
                let plane = planeEntry.value
                let faces = plane.geometry.meshFaces
                
                // VRR can't do lines
                if faces.primitive != GeometryElement.Primitive.triangle {
                    continue
                }
                
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
                
                //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
                self.planeUniforms[0].planeColor = planeToLineColor(plane: plane)
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                    indexCount: faces.count*3,
                                                    indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                    indexBuffer: faces.buffer,
                                                    indexBufferOffset: 0)
            }
        }
        
        WorldTracker.shared.unlockPlaneAnchors()
        
        WorldTracker.shared.lockDebuggables()
        
        // Render lines
        for i in 0..<WorldTracker.shared.debuggableMats.count {
            let matTransform = WorldTracker.shared.debuggableMats[i]
            let basisColors = [simd_float4(1.0, 0.0, 0.0, 1.0), simd_float4(0.0, 1.0, 0.0, 1.0), simd_float4(0.0, 0.0, 1.0, 1.0)]
            let basisScaleFactor: Float = WorldTracker.shared.debuggableScales[i]
            let basisScale = simd_float3x3(basisScaleFactor).asFloat4x4()
            
            for i in 0..<3 {
                renderEncoder.setVertexBuffer(unitVectorXYZBuffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(unitVectorXYZBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
                
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = (matTransform.columns.3.asFloat3()).asFloat4x4() * (basisScale * matTransform.orientationOnly().asFloat4x4())
                self.planeUniforms[0].planeColor = basisColors[i]
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 3*i, vertexCount: 3)
            }
        }
        
        WorldTracker.shared.debuggableMats = []
        WorldTracker.shared.debuggableScales = []
        WorldTracker.shared.unlockDebuggables()
        
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    // Renders the chaperone proximity overlay on top of the existing video frame.
    func renderChaperone(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?, simdDeviceAnchor: simd_float4x4) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Chaperone Render Encoder"
        renderEncoder.pushDebugGroup("Draw chaperone")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif

        let planesSnapshot = WorldTracker.shared.snapshotPlaneData()
#if CHAPERONE_PROFILE
        let profileStart = CACurrentMediaTime()
#endif
        let output = chaperoneSystem.update(planes: planesSnapshot,
                                            headPose: simdDeviceAnchor,
                                            leftHandPose: WorldTracker.shared.lastLeftHandPose,
                                            rightHandPose: WorldTracker.shared.lastRightHandPose,
                                            worldFromSteamVR: WorldTracker.shared.worldTrackingSteamVRTransform,
                                            chaperoneDistanceCm: ALVRClientApp.gStore.settings.chaperoneDistanceCm,
                                            now: CACurrentMediaTime(),
                                            leftControllerPresent: WorldTracker.shared.leftControllerPose != nil,
                                            rightControllerPresent: WorldTracker.shared.rightControllerPose != nil) { isLeft, amplitude, duration in
            WorldTracker.shared.enqueueHapticsPulse(isLeft: isLeft, amplitude: amplitude, duration: duration)
        }

#if CHAPERONE_PROFILE
        let elapsedMs = (CACurrentMediaTime() - profileStart) * 1000.0
        chaperoneProfileAccumMs += elapsedMs
        chaperoneProfileSamples += 1
        chaperoneProfileWindow.append(elapsedMs)
        if chaperoneProfileWindow.count > chaperoneProfileWindowSize {
            chaperoneProfileWindow.removeFirst(chaperoneProfileWindow.count - chaperoneProfileWindowSize)
        }
        let now = CACurrentMediaTime()
        if now - chaperoneProfileLastLog > 2.0 {
            chaperoneProfileLastLog = now
            let avg = chaperoneProfileAccumMs / Double(max(1, chaperoneProfileSamples))
            let maxSample = chaperoneProfileWindow.max() ?? 0.0
            var median: Double = 0.0
            if !chaperoneProfileWindow.isEmpty {
                let sorted = chaperoneProfileWindow.sorted()
                median = sorted[sorted.count / 2]
            }
            let recomputeSamples = max(1, output.profile.recomputeSamples)
            let recomputePct = Int((Double(output.profile.recomputeTrue) / Double(recomputeSamples)) * 100.0)
            let avgRenderables = Double(output.profile.renderableCount) / Double(recomputeSamples)
            print("[ChaperoneProfile] avg=\(String(format: "%.3f", avg))ms median=\(String(format: "%.3f", median))ms max=\(String(format: "%.3f", maxSample))ms samples=\(chaperoneProfileSamples) planes=\(planesSnapshot.count) recompute=\(recomputePct)% exact=\(output.profile.exactProximityChecks) renderables=\(String(format: "%.1f", avgRenderables)) interval=\(output.profile.recomputeIntervalFrames)")
            chaperoneProfileAccumMs = 0.0
            chaperoneProfileSamples = 0
        }
#endif

        var firstBind = true
        for (plane, planeColor) in output.renderables {
            let faces = plane.geometry.meshFaces

            // VRR can't do lines
            if faces.primitive != GeometryElement.Primitive.triangle {
                continue
            }

            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)

            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeColor
            self.planeUniforms[0].planeDoProximity = 1.0
            if firstBind {
                renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                firstBind = false
            } else {
                renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            }
            
            renderEncoder.setTriangleFillMode(.fill)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }

        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    func renderPerformanceHud(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?, simdDeviceAnchor: simd_float4x4) {
        guard ALVRClientApp.gStore.settings.showPerformanceHud else { return }
        if performanceHudRenderer == nil {
            performanceHudRenderer = PerformanceHudRenderer(device: device)
        }
        guard let hudTexture = performanceHudRenderer?.updateIfNeeded() else { return }
        selectNextPlaneUniformBuffer()
        let worldFromSteamVR = WorldTracker.shared.worldTrackingSteamVRTransform
        let handPose = WorldTracker.shared.lastLeftHandPose
        let handWorld = worldFromSteamVR * handPose.asFloat4x4()
        let handPosition = handWorld.columns.3.asFloat3()
        var handRight = simd_normalize(handWorld.columns.0.asFloat3())
        let handUp = simd_normalize(handWorld.columns.1.asFloat3())
        let handForward = simd_normalize(handWorld.columns.2.asFloat3())
        if simd_length(handRight) < 0.001 || simd_length(handUp) < 0.001 || simd_length(handForward) < 0.001 {
            return
        }
        handRight = simd_normalize(handRight)
        // Hand axes derived from the current left-hand pose.
        // thumbAxis: toward thumb side of the hand (local +X).
        // palmAxis: palm normal (local +Y).
        // elbowAxis: from fingers toward wrist/elbow (local -Z).
        let thumbAxis = -handForward
        let palmAxis = handRight
        let elbowAxis = handUp

        // Panel axes in world space:
        // panelFront: the face normal of the panel (should align with palmAxis).
        // panelTopEdge: the top edge of the panel (should align with elbowAxis).
        // panelRightEdge: the right edge of the panel (perpendicular to both).
        let panelFront = simd_normalize(-palmAxis)
        var panelTopEdge = simd_normalize(-elbowAxis)
        var panelRightEdge = simd_normalize(-thumbAxis)
        let palmTwist = simd_quatf(angle: Float.pi / 180.0 * 20.0, axis: simd_normalize(palmAxis))
        panelTopEdge = simd_normalize(palmTwist.act(panelTopEdge))
        panelRightEdge = simd_normalize(palmTwist.act(panelRightEdge))
        let forearmDir = panelTopEdge

        // Orientation uses panelRightEdge (X), panelTopEdge (Y), panelFront (Z).
        let orientation = simd_float4x4(simd_float4(panelRightEdge, 0.0),
                                        simd_float4(panelTopEdge, 0.0),
                                        simd_float4(panelFront, 0.0),
                                        simd_float4(0.0, 0.0, 0.0, 1.0))
        // Position offsets:
        // offsetIn: shift toward the inner forearm (away from thumb).
        // offsetArm: shift toward elbow along the forearm.
        // offsetDown: move slightly into the arm to sit on the surface.
        let offsetIn = simd_float3()
        let offsetArm = -forearmDir * 0.10
        let offsetDown = panelFront * 0.025
        let offset = offsetIn + offsetArm + offsetDown
        let position = handPosition + offset
        let translation = position.asFloat4x4()
        let sizeY: Float = 0.07
        let aspect = Float(hudTexture.width) / Float(hudTexture.height)
        let sizeX: Float = sizeY * aspect
        let scale = simd_float4x4(simd_float4(sizeX, 0.0, 0.0, 0.0),
                                  simd_float4(0.0, sizeY, 0.0, 0.0),
                                  simd_float4(0.0, 0.0, 1.0, 0.0),
                                  simd_float4(0.0, 0.0, 0.0, 1.0))
        let transform = translation * orientation * scale

        self.planeUniforms[0].planeTransform = transform
        self.planeUniforms[0].planeColor = simd_float4(1.0, 1.0, 1.0, 1.0)
        self.planeUniforms[0].planeDoProximity = 0.0

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .load
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create HUD render encoder")
        }

        renderEncoder.label = "HUD Render Encoder"
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset: planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        renderEncoder.setRenderPipelineState(hudPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlwaysNoWrite)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        renderEncoder.setVertexBuffer(hudQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(hudQuadBuffer, offset: (3 * 4) * 4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.setFragmentTexture(hudTexture, index: TextureIndex.color.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
    }
    
    // Sets up rendering a video frame, including uniforms
    func beginRenderStreamingFrame(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) -> (any MTLRenderCommandEncoder)? {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return nil
        }
        
        // TODO refactor this
        if isRealityKit {
            fadeInOverlayAlpha -= 0.01
            if fadeInOverlayAlpha < 0.0 {
                fadeInOverlayAlpha = 0.0
            }
        }
    
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = whichIdx == 0 ? (isRealityKit ? .dontCare : .clear) : .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: chromaKeyEnabled ? 0.0 : 1.0)
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Primary Render Encoder"
        renderEncoder.pushDebugGroup("Draw ALVR Frames")
        
        guard let queuedFrame = queuedFrame else {
            renderEncoder.endEncoding()
            return nil
        }
        
        // https://cs.android.com/android/platform/superproject/main/+/main:external/webrtc/sdk/objc/components/renderer/metal/RTCMTLNV12Renderer.mm;l=108;drc=a81e9c82fc3fbc984f0f110407d1e44c9c01958a
        let pixelBuffer = queuedFrame.imageBuffer
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let formatStr = VideoHandler.coreVideoPixelFormatToStr[format, default: "unknown"]
        
        if VideoHandler.isFormatSecret(format) {
            renderEncoder.setRenderPipelineState(videoFramePipelineState_SecretYpCbCrFormats)
        }
        else {
            renderEncoder.setRenderPipelineState(videoFramePipelineState_YpCbCrBiPlanar)
        }
        
        //print("Pixel format \(formatStr) (\(format))")
        let textureTypes = VideoHandler.getTextureTypesForFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))
        
        for i in 0...1 {
            var textureOut:CVMetalTexture! = nil
            var err:OSStatus = 0
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i)
            
            if textureTypes[i] == MTLPixelFormat.invalid {
                break
            }
            
            err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, textureTypes[i],
                    width, height, i, &textureOut);
            
            if err != 0 {
                fatalError("CVMetalTextureCacheCreateTextureFromImage \(err)")
            }
            guard let metalTexture = CVMetalTextureGetTexture(textureOut) else {
                fatalError("CVMetalTextureGetTexture")
            }
            if !((metalTexture.debugDescription?.contains("decompressedPixelFormat") ?? true) || (metalTexture.debugDescription?.contains("isCompressed = 1") ?? true)) && EventHandler.shared.totalFramesRendered % 90*5 == 0 {
                print("NO COMPRESSION ON VT FRAME!!!! AAAAAAAAA go file feedback again :(")
            }
            renderEncoder.setFragmentTexture(metalTexture, index: i)
        }
        
        // Snoop for pixel formats
        /*for idx in 620..<0xFFFF {
            guard let format = MTLPixelFormat.init(rawValue: UInt(idx)) else {
                continue
            }
            do {
                var desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MTLPixelFormat.invalid, width: 1, height:1, mipmapped: false)
                desc.pixelFormat = format
                for line in desc.debugDescription.split(separator: "\n") {
                    if line.contains("pixelFormat") {
                        print(idx, line)
                        break
                    }
                }
            }
            catch {
                continue
            }
        }*/
        
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.counterClockwise)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        return renderEncoder
    }
    
    // Actually do the video frame render.
    func renderStreamingFrame(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderEncoder: any MTLRenderCommandEncoder, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: whichIdx*4, vertexCount: 4)
    }
    
    // Finish video frame encoding.
    func endRenderStreamingFrame(renderEncoder: any MTLRenderCommandEncoder) {
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // Render an overlay on top of the video frame.
    func renderStreamingFrameOverlays(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
    
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        if fadeInOverlayAlpha > 0.0 || WorldTracker.shared.debuggableMats.count > 0 {
            // Not super kosher--we need the depth to be correct for the video frame box, but we can't have the view
            // outside of the video frame box be 0.0 depth or it won't get rastered by the compositor at all.
            // So we re-render the frame depth.
            renderOverlay(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        }
        if ALVRClientApp.gStore.settings.chaperoneDistanceCm > 0 || chaperoneSystem.hasActiveState {
            renderChaperone(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, rasterizationRateMap: rasterizationRateMap, simdDeviceAnchor: simdDeviceAnchor)
        }
        if !isRealityKit {
            renderStreamingFrameDepth(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame)
        }
        if !isRealityKit && ALVRClientApp.gStore.settings.showPerformanceHud {
            renderPerformanceHud(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, rasterizationRateMap: rasterizationRateMap, simdDeviceAnchor: simdDeviceAnchor)
        }
    }
}
