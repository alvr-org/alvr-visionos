//
//  RealityKitClientSystem.swift
//
// This is the RealityKit counterpart to MetalClientSystem, which handles
// per-frame updates. Setup is as follows:
//
// await RealityKitClientSystem.setup(content)
// MagicRealityKitClientSystemComponent.registerComponent()
// RealityKitClientSystem.registerSystem()
//
// Notable components include:
// - VSync/presentation time prediction (VisionProVsyncPrediction)
// - DrawableQueue/LowLevelTexture render targets (DrawableWrapper)
// - (Fixed) Variable Rasterization Rate to avoid GPU memory write bandwidth,
//   and in the future, on-the-fly resolution changes (createVRRMeshResource/createVRR)
// - Per-eye (L/R) and atomic (A/B) pose updates for the RealityKit quads
// - View information stolen from Metal (DummyMetalRenderer)
// - Shared render code with Metal (Renderer)
//
// In contrast with the Metal renderer, the RealityKit renderer always renders
// perfectly orthogonally (with the reported headset pose matching QueuedFrame's pose)
// so that any resampling losses only happen in the RealityKit system renderer.
//

import SwiftUI
import RealityKit
import ARKit
import QuartzCore
import Metal
import MetalKit
import Spatial
import AVFoundation

let vrrGridSizeX = 59+1
let vrrGridSizeY = 57+1
let renderWidth = Int(1888)
let renderHeight = Int(1824)
let renderScale = 1.75
let renderColorFormatSDR = MTLPixelFormat.bgra8Unorm_srgb // rgba8Unorm, rgba8Unorm_srgb, bgra8Unorm, bgra8Unorm_srgb, rgba16Float
var renderColorFormatHDR = MTLPixelFormat.rgba16Float // bgr10_xr_srgb? rg11b10Float? rgb9e5?--rgb9e5 is probably not renderable.
let renderColorFormatDrawableSDR = renderColorFormatSDR
var renderColorFormatDrawableHDR = MTLPixelFormat.rgba16Float
let renderColorFormatVisionOS2HDR = MTLPixelFormat.rgba16Float // idk, if I ever want to change it? other texture formats don't do well tbh
let renderColorFormatDrawableVisionOS2HDR = MTLPixelFormat.rgba16Float
let renderDepthFormat = MTLPixelFormat.depth16Unorm
let renderViewCount = 2
let renderZNear = 0.001
let renderZFar = 1000.0
let rkFramesInFlight = 3
let realityKitRenderScale: Float = 2.25
#if XCODE_BETA_16
let forceDrawableQueue = false
#else
let forceDrawableQueue = true
#endif
let useTripleBufferingStaleTextureVisionOS2Hack = true

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.

let rk_panel_depth: Float = 90
let rk_panel_depth: Float = 80

struct RKQueuedFrame {
    let texture: MTLTexture
    let depthTexture: MTLTexture
    let timestamp: UInt64
    let transform: simd_float4x4
    let vsyncTime: Double
    let vrrMap: MTLRasterizationRateMap
    let vrrBuffer: MTLBuffer
}

struct VrrPlaneVertex {
    var position: simd_float3 = .zero
    var uv: simd_float2 = .zero
}

class VisionProVsyncPrediction: NSObject, ObservableObject {
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
        
        // HACK: We need to do this early somewhere, so I chose here.
        if #available(visionOS 2.0, *) {
            renderColorFormatHDR = renderColorFormatVisionOS2HDR
            renderColorFormatDrawableHDR = renderColorFormatDrawableVisionOS2HDR
        }
    }
    
    static func setup(_ content: RealityViewContent) async {
        
        await MainActor.run {
            let materialBackdrop = UnlitMaterial(color: .black)

            var materialInputCatcher = UnlitMaterial(color: .init(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0))
            materialInputCatcher.blending = .transparent(opacity: 0.0)
            if #available(visionOS 2.0, *) {
                materialInputCatcher.writesDepth = false
            }
            
            let videoPlaneMeshCollision = MeshResource.generatePlane(width: 1.0, depth: 1.0)
            let cubeMesh = MeshResource.generateBox(size: 1.0)
            try? cubeMesh.addInvertedNormals()
            
            let anchor = AnchorEntity(.head)
            anchor.anchoring.trackingMode = .continuous
            anchor.name = "backdrop_headanchor"
            anchor.position = simd_float3(0.0, 0.0, 0.0)
            
            // L/R planes for each eye, as well as A/B to ensure texture
            // updates are atomic with pose updates
            let videoPlaneA_L = Entity()
            videoPlaneA_L.name = "video_plane_a_L"
            videoPlaneA_L.components.set(MagicRealityKitClientSystemComponent())

            videoPlaneA_L.components.set(InputTargetComponent())
            videoPlaneA_L.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            videoPlaneA_L.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneA_L.isEnabled = false
            
            let videoPlaneB_L = Entity()
            videoPlaneB_L.name = "video_plane_b_L"
            videoPlaneB_L.components.set(MagicRealityKitClientSystemComponent())

            videoPlaneB_L.components.set(InputTargetComponent())
            videoPlaneB_L.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            videoPlaneB_L.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneB_L.isEnabled = false
            
            let videoPlaneC_L = Entity()
            videoPlaneC_L.name = "video_plane_c_L"
            videoPlaneC_L.components.set(MagicRealityKitClientSystemComponent())

            videoPlaneC_L.components.set(InputTargetComponent())
            videoPlaneC_L.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            videoPlaneC_L.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneC_L.isEnabled = false
            
            let videoPlaneA_R = Entity()
            videoPlaneA_R.name = "video_plane_a_R"
            videoPlaneA_R.components.set(MagicRealityKitClientSystemComponent())

            videoPlaneA_R.components.set(InputTargetComponent())
            videoPlaneA_R.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            videoPlaneA_R.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneA_R.isEnabled = false
            
            let videoPlaneB_R = Entity()
            videoPlaneB_R.name = "video_plane_b_R"
            videoPlaneB_R.components.set(MagicRealityKitClientSystemComponent())

            videoPlaneB_R.components.set(InputTargetComponent())
            videoPlaneB_R.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            videoPlaneB_R.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneB_R.isEnabled = false
            
            let videoPlaneC_R = Entity()
            videoPlaneC_R.name = "video_plane_c_R"
            videoPlaneC_R.components.set(MagicRealityKitClientSystemComponent())

            videoPlaneC_R.components.set(InputTargetComponent())
            videoPlaneC_R.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            videoPlaneC_R.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneC_R.isEnabled = false
            videoPlaneC_R.scale = simd_float3(0.0, 0.0, 0.0)
            videoPlaneC_R.isEnabled = false
            
            let checkFloorLevelingPlane = ModelEntity(mesh: videoPlaneMeshCollision, materials: [materialBackdrop])
            checkFloorLevelingPlane.name = "check_floor_leveling_plane"
            checkFloorLevelingPlane.position = simd_float3(0.0, 0.0, 0.0)
            checkFloorLevelingPlane.scale = simd_float3(0.1, 0.1, 0.1)
            checkFloorLevelingPlane.isEnabled = false

            let backdrop = ModelEntity(mesh: videoPlaneMeshCollision, materials: [materialBackdrop])
            backdrop.name = "backdrop_plane"
            backdrop.isEnabled = false
            
            anchor.addChild(backdrop)

            
            // We need to make sure all input rays hit the input catcher, because if it hits the video planes
            // then inputs will randomly cancel
            let input_catcher = ModelEntity(mesh: videoPlaneMeshCollision, materials: [materialInputCatcher])
            input_catcher.components.set(InputTargetComponent())
            input_catcher.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMeshCollision)]))
            input_catcher.name = "input_catcher"
            
            let input_catcher_depth: Float = 1.5//(rk_panel_depth * 0.5)
            input_catcher.position = simd_float3(0.0, 0.0, -input_catcher_depth)
            input_catcher.orientation = simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
            input_catcher.scale = simd_float3(input_catcher_depth * 4.0, input_catcher_depth * 4.0, input_catcher_depth * 4.0) // TODO: view tangents over 4.0? idk
            input_catcher.isEnabled = true
            
            anchor.addChild(input_catcher)

            content.add(videoPlaneA_L)
            content.add(videoPlaneB_L)
            content.add(videoPlaneC_L)
            content.add(videoPlaneA_R)
            content.add(videoPlaneB_R)
            content.add(videoPlaneC_R)

            content.add(checkFloorLevelingPlane)
            content.add(anchor)
        }
    }
    
    func update(context: SceneUpdateContext) {
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

class DrawableWrapper {
    var wrapped: AnyObject? = nil
    var drawable: AnyObject? = nil
    var textureResource: TextureResource? = nil
    var texture: MTLTexture? = nil
    
    @MainActor init(pixelFormat: MTLPixelFormat, width: Int, height: Int, usage: MTLTextureUsage, isBiplanar: Bool) {
#if XCODE_BETA_16
        if #available(visionOS 2.0, *), !forceDrawableQueue {
            if isBiplanar {
                let desc = LowLevelTexture.Descriptor(textureType: .type2DArray, pixelFormat: pixelFormat, width: width, height: height/renderViewCount, depth: 1, mipmapLevelCount: 1, arrayLength: renderViewCount, textureUsage: usage)
                let tex = try? LowLevelTexture(descriptor: desc)
                self.wrapped = tex
            }
            else {
                let desc = LowLevelTexture.Descriptor(textureType: .type2D, pixelFormat: pixelFormat, width: width, height: height, depth: 1, mipmapLevelCount: 1, arrayLength: 1, textureUsage: usage)
                let tex = try? LowLevelTexture(descriptor: desc)
                self.wrapped = tex
            }
            return
        }
#endif
        let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: pixelFormat, width: width, height: height, usage: [usage], mipmapsMode: .none)
        let queue = try? TextureResource.DrawableQueue(desc)
        queue!.allowsNextDrawableTimeout = true
        self.wrapped = queue
    }
    
    func makeTextureResource() -> TextureResource? {
#if XCODE_BETA_16
        if #available(visionOS 2.0, *) {
            if let tex = wrapped as? LowLevelTexture {
                self.textureResource = try! TextureResource(from: tex)
                return self.textureResource
            }
        }
#endif
        
        if let queue = wrapped as? TextureResource.DrawableQueue {
            if self.textureResource == nil {
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
            }
            self.textureResource?.replace(withDrawables: queue)
            
            return self.textureResource
        }
        
        return nil
    }
    
    @MainActor func nextTexture(commandBuffer: MTLCommandBuffer) -> MTLTexture? {
#if XCODE_BETA_16
        if #available(visionOS 2.0, *) {
            if let tex = wrapped as? LowLevelTexture {
                if self.texture != nil {
                    return self.texture
                }
                let writeTexture: MTLTexture = tex.replace(using: commandBuffer)
                
                // HACK: Ewwwwwwwww
                if useTripleBufferingStaleTextureVisionOS2Hack {
                    self.texture = writeTexture
                }
                return writeTexture
            }
        }
#endif
        
        if let queue = wrapped as? TextureResource.DrawableQueue {
            let drawable = try? queue.nextDrawable()
            self.drawable = drawable
            return drawable?.texture
        }
        
        return nil
    }
    
    @MainActor func present(commandBuffer: MTLCommandBuffer) {
#if XCODE_BETA_16
        if #available(visionOS 2.0, *) {
            if wrapped as? LowLevelTexture != nil {
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                return
            }
        }
#endif
        if let drawable = self.drawable as? TextureResource.Drawable {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            drawable.presentOnSceneUpdate()
        }
    }
}

class RealityKitClientSystemCorrectlyAssociated : System {
    let visionProVsyncPrediction = VisionProVsyncPrediction()
    var lastUpdateTime = 0.0
    var drawableQueueA: DrawableWrapper? = nil
    var drawableQueueB: DrawableWrapper? = nil
    var drawableQueueC: DrawableWrapper? = nil
    private var textureResourceA: TextureResource? = nil
    private var textureResourceB: TextureResource? = nil
    private var textureResourceC: TextureResource? = nil
    private var meshResourceL: MeshResource? = nil
    private var meshResourceR: MeshResource? = nil
    private(set) var surfaceMaterialA_L: ShaderGraphMaterial? = nil
    private(set) var surfaceMaterialB_L: ShaderGraphMaterial? = nil
    private(set) var surfaceMaterialC_L: ShaderGraphMaterial? = nil
    private(set) var surfaceMaterialA_R: ShaderGraphMaterial? = nil
    private(set) var surfaceMaterialB_R: ShaderGraphMaterial? = nil
    private(set) var surfaceMaterialC_R: ShaderGraphMaterial? = nil
    var setPlaneMaterialA_L = false
    var setPlaneMaterialB_L = false
    var setPlaneMaterialC_L = false
    var setPlaneMaterialA_R = false
    var setPlaneMaterialB_R = false
    var setPlaneMaterialC_R = false
    var passthroughPipelineState: MTLRenderPipelineState? = nil
    var passthroughPipelineStateHDR: MTLRenderPipelineState? = nil
    var meshHasVrr = false
    
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var renderViewports: [MTLViewport] = [MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0), MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0)]

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
    var dynamicallyAdjustRenderScale: Bool = false
    
    var rkFramePool = [(MTLTexture, MTLTexture, MTLBuffer)]()
    var rkFrameQueue = [RKQueuedFrame]()
    var rkFramePoolLock = NSObject()
    var rkFramesRendered = 0
    
    var reprojectedFramesInARow: Int = 0
    
    var lastSubmit = 0.0
    var lastUpdate = 0.0
    var lastLastSubmit = 0.0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    var currentHzAvg: Double = 90.0
    
    var renderer: Renderer
    
    var renderTangents = [simd_float4(1.73205, 1.0, 1.0, 1.19175), simd_float4(1.0, 1.73205, 1.0, 1.19175)]
    var copyVertices = [simd_float3](repeating: simd_float3(), count: ((vrrGridSizeY-1)*vrrGridSizeX*2)*2)
    var copyVerticesBuffer: MTLBuffer? = nil
    
    required init(scene: RealityKit.Scene) {
        print("RealityKitClientSystem init")
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
        
        // Generate VRR mesh
        // TODO: can this be done faster? (per-frame)
        for vertexID in 0..<((vrrGridSizeY-1)*vrrGridSizeX*2)*renderViewCount {
            let x = (vertexID >> 1) % vrrGridSizeX
            let y = (vertexID & 1) + (((vertexID >> 1) / vrrGridSizeX) % (vrrGridSizeY-1))
            let which = (vertexID >= (vrrGridSizeY-1)*vrrGridSizeX*2) ? 1 : 0 // TODO people with three eyes (renderViewCount)
            
            copyVertices[vertexID] = simd_float3((Float(x) / Float(vrrGridSizeX - 1)), (Float(y) / Float(vrrGridSizeY - 1)), (which != 0) ? 1.0 : 0.0)
        }
        copyVertices.withUnsafeBytes {
            copyVerticesBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }

        currentSetRenderScale = realityKitRenderScale
        if realityKitRenderScale <= 0.0 {
            currentRenderScale = Float(renderScale)
            dynamicallyAdjustRenderScale = true
        }
        else {
            currentRenderScale = currentSetRenderScale
            dynamicallyAdjustRenderScale = false
        }
        
        if let event = EventHandler.shared.streamEvent?.STREAMING_STARTED {
            currentOffscreenRenderScale = Float(event.view_width) / Float(renderWidth)
            
            currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
            currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))
        }
        
        let vrr = createVRR() // HACK
        
        if meshHasVrr {
            currentRenderWidth = currentOffscreenRenderWidth
            currentRenderHeight = currentOffscreenRenderHeight
            currentRenderScale = Float(currentRenderWidth) / Float(renderWidth)
        }
        else {
            currentRenderWidth = vrr.screenSize.width//Int(Double(renderWidth) * Double(currentRenderScale))
            currentRenderHeight = vrr.screenSize.height//Int(Double(renderHeight) * Double(currentRenderScale))
            currentRenderScale = Float(currentRenderWidth) / Float(renderWidth)
        }
        
        currentRenderColorFormat = renderer.currentRenderColorFormat
        currentDrawableRenderColorFormat = renderer.currentDrawableRenderColorFormat
        lastRenderColorFormat = currentRenderColorFormat
        lastRenderScale = currentRenderScale
        lastOffscreenRenderScale = currentOffscreenRenderScale

        self.drawableQueueA = DrawableWrapper(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*renderViewCount, usage: .renderTarget, isBiplanar: meshHasVrr)
        self.drawableQueueB = DrawableWrapper(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*renderViewCount, usage: .renderTarget, isBiplanar: meshHasVrr)
        self.drawableQueueC = DrawableWrapper(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*renderViewCount, usage: .renderTarget, isBiplanar: meshHasVrr)
        
        // Dummy texture
        self.textureResourceA = self.drawableQueueA!.makeTextureResource()
        self.textureResourceB = self.drawableQueueB!.makeTextureResource()
        self.textureResourceC = self.drawableQueueC!.makeTextureResource()
        
        Task {
            var filter = "Bicubic"
            var base = "/Root/SBSMaterial"
            if currentRenderScale > 1.8 { // arbitrary, TODO actually benchmark this idk
                filter = "Bilinear"
            }
            if meshHasVrr {
                base = "/Root/BiplanarMaterial"
                filter = "Bilinear"
            }
            self.surfaceMaterialA_L = try! await ShaderGraphMaterial(
                named: base + filter + "_L",
                from: "SBSMaterial.usda"
            )

#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialA_L?.readsDepth = false
                self.surfaceMaterialA_L?.writesDepth = false
            }
#endif
            self.surfaceMaterialB_L = try! await ShaderGraphMaterial(
                named: base + filter + "_L",
                from: "SBSMaterial.usda"
            )

#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialB_L?.readsDepth = false
                self.surfaceMaterialB_L?.writesDepth = false
            }
#endif
            self.surfaceMaterialC_L = try! await ShaderGraphMaterial(
                named: base + filter + "_L",
                from: "SBSMaterial.usda"
            )

            
#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialC_L?.readsDepth = false
                self.surfaceMaterialC_L?.writesDepth = false
            }
#endif

            self.surfaceMaterialA_R = try! await ShaderGraphMaterial(
                named: base + filter + "_R",
                from: "SBSMaterial.usda"
            )

#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialA_R?.readsDepth = false
                self.surfaceMaterialA_R?.writesDepth = false
            }
#endif
            self.surfaceMaterialB_R = try! await ShaderGraphMaterial(
                named: base + filter + "_R",
                from: "SBSMaterial.usda"
            )

#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialB_R?.readsDepth = false
                self.surfaceMaterialB_R?.writesDepth = false
            }
#endif
            self.surfaceMaterialC_R = try! await ShaderGraphMaterial(
                named: base + filter + "_R",
                from: "SBSMaterial.usda"
            )

            
#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialA_L?.readsDepth = false
                self.surfaceMaterialB_L?.readsDepth = false
                self.surfaceMaterialC_L?.readsDepth = false
                self.surfaceMaterialA_R?.readsDepth = false
                self.surfaceMaterialB_R?.readsDepth = false
                self.surfaceMaterialC_R?.readsDepth = false
            }
#endif

            // A weird bug happened here, only surfaceMaterialC_R had readsDepth set correctly?
            // Turns out we don't want this anyway, causes the app to render in front of windows
            // and hands

#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                self.surfaceMaterialC_R?.readsDepth = false
                self.surfaceMaterialC_R?.writesDepth = false
            }
#endif

        }
        
        recreateFramePool()
        createCopyShaderPipelines()
        
        print("Offscreen render res:", currentOffscreenRenderWidth, "x", currentOffscreenRenderHeight, "(", currentOffscreenRenderScale, ")")
        print("Offscreen render res foveated:", vrr.physicalSize(layer: 0).width, "x", vrr.physicalSize(layer: 0).height, "(", Float(vrr.physicalSize(layer: 0).width) / Float(renderWidth), ")")
        print("RK render res:", currentRenderWidth, "x", currentRenderHeight, "(", currentRenderScale, ")")

        EventHandler.shared.handleRenderStarted()
        EventHandler.shared.renderStarted = true
    }
    
    // Create offscreen->Drawable copy pipelines for both HDR and SDR
    @MainActor func createCopyShaderPipelines()
    {
        let vrrMap = createVRR() // HACK
        var formatHDR = renderColorFormatDrawableHDR
        if #available(visionOS 2.0, *) {
            formatHDR = renderColorFormatDrawableVisionOS2HDR
        }
        
        self.passthroughPipelineState = try! renderer.buildCopyPipelineWithDevice(device: device, colorFormat: renderColorFormatSDR, viewCount: 1, vrrScreenSize: vrrMap.screenSize, vrrPhysSize: vrrMap.physicalSize(layer: 0),  vertexShaderName: "copyVertexShader", fragmentShaderName: "copyFragmentShader")
        self.passthroughPipelineStateHDR = try! renderer.buildCopyPipelineWithDevice(device: device, colorFormat: formatHDR, viewCount: 1, vrrScreenSize: vrrMap.screenSize, vrrPhysSize: vrrMap.physicalSize(layer: 0),  vertexShaderName: "copyVertexShader", fragmentShaderName: "copyFragmentShader")
    }
    
    // Create a VRR mesh if on visionOS 2.0, which allows us to shave off an entire millisecond of
    // copying
    @MainActor func createVRRMeshResource(_ which: Int, _ vrrMap: MTLRasterizationRateMap) throws -> MeshResource {
#if XCODE_BETA_16
        if #available(visionOS 2.0, *), !forceDrawableQueue {
            let vertexAttributes: [LowLevelMesh.Attribute] = [
                .init(semantic: .position, format: .float3, offset: MemoryLayout<VrrPlaneVertex>.offset(of: \.position)!),
                .init(semantic: .uv0, format: .float2, offset: MemoryLayout<VrrPlaneVertex>.offset(of: \.uv)!)
            ]


            let vertexLayouts: [LowLevelMesh.Layout] = [
                .init(bufferIndex: 0, bufferStride: MemoryLayout<VrrPlaneVertex>.stride)
            ]

            var desc = LowLevelMesh.Descriptor()
            desc.vertexAttributes = vertexAttributes
            desc.vertexLayouts = vertexLayouts
            desc.indexType = .uint32

            let generatedGridSizeX = vrrGridSizeX
            let generatedGridSizeY = vrrGridSizeY
            desc.vertexCapacity = generatedGridSizeX*generatedGridSizeY
            desc.indexCapacity = ((generatedGridSizeY-1)*generatedGridSizeX*2)
            
            let mesh = try LowLevelMesh(descriptor: desc)

            // Generate vertices
            mesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBytes in
                let vertices = rawBytes.bindMemory(to: VrrPlaneVertex.self)
                
                var vertexID = 0
                for y in 0..<generatedGridSizeY {
                    for x in 0..<generatedGridSizeX {
                        let uvx = (Float(x) / Float(generatedGridSizeX - 1))
                        let uvy = (Float(y) / Float(generatedGridSizeY - 1))
                        let px = uvx - 0.5
                        let py = uvy - 0.5
                        
                        let physicalCoordinates = vrrMap.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: uvx * Float(vrrMap.screenSize.width), y: uvy * Float(vrrMap.screenSize.height)), layer: which)
                        let real_uvx = (physicalCoordinates.x / Float(vrrMap.screenSize.width))
                        let real_uvy = (physicalCoordinates.y / Float(vrrMap.screenSize.height))
                        
                        vertices[vertexID].position = simd_float3(px, 0.0, py)
                        vertices[vertexID].uv = simd_float2(real_uvx, real_uvy)
                        vertexID += 1
                    }
                }
            }
            
            // Generate indices
            // TODO: this could be simplified by moving the left/right stuff up ^
            let verticesPerRow = generatedGridSizeX
            var indexID = 0
            mesh.withUnsafeMutableIndices { rawIndices in
                let indices = rawIndices.bindMemory(to: UInt32.self)
                
                for y in 0..<1 {
                    for x in 0..<verticesPerRow {
                        indices[indexID] = UInt32((y * verticesPerRow) + x)
                        indexID += 1
                        indices[indexID] = UInt32(((y + 1) * verticesPerRow) + x)
                        indexID += 1
                    }
                }
                
                for y in 1..<generatedGridSizeY-1 {
                    if y & 1 == 0 {
                        // left to right
                        for x in 0..<verticesPerRow {
                            indices[indexID] = UInt32((y * verticesPerRow) + x)
                            if indices[indexID] != indices[indexID-1] {
                                indexID += 1
                            }
                            indices[indexID] = UInt32(((y + 1) * verticesPerRow) + x)
                            if indices[indexID] != indices[indexID-1] {
                                indexID += 1
                            }
                        }
                    } else {
                        // right to left
                        for x in (0..<verticesPerRow).reversed() {
                            indices[indexID] = UInt32((y * verticesPerRow) + x)
                            if indices[indexID] != indices[indexID-1] {
                                indexID += 1
                            }
                            indices[indexID] = UInt32(((y + 1) * verticesPerRow) + x)
                            if indices[indexID] != indices[indexID-1] {
                                indexID += 1
                            }
                        }
                    }
                }
            }
            let numIndices = indexID
            
            let meshBounds = BoundingBox(min: [-0.5, 0, -0.5], max: [0.5, 0, 0.5])
            let parts: [LowLevelMesh.Part] = [
                    LowLevelMesh.Part(
                    indexOffset: 0,
                    indexCount: numIndices,
                    topology: .triangleStrip,
                    bounds: meshBounds
                )
            ]
            mesh.parts.replaceAll(parts)
            
            meshHasVrr = true
            return try MeshResource(from: mesh)
        }
#endif

        // visionOS 1.x
        meshHasVrr = false
        let videoPlaneMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)
        return videoPlaneMesh
    }
    
    // Create a Variable Rasterization Rate
    @MainActor func createVRR() -> MTLRasterizationRateMap {
        let descriptor = MTLRasterizationRateMapDescriptor()
        descriptor.label = "Offscreen VRR"

        currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
        currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))

        let vrrGridPartitionsX = vrrGridSizeX-1
        let vrrGridPartitionsY = vrrGridSizeY-1
        let layerWidth = Int(currentOffscreenRenderWidth / vrrGridPartitionsX) * vrrGridPartitionsX
        let layerHeight = Int(currentOffscreenRenderHeight / vrrGridPartitionsY) * vrrGridPartitionsY
        descriptor.screenSize = MTLSizeMake(layerWidth, layerHeight, renderViewCount)

        // i==0 => left eye, i==1 -> right eye
        let zoneCounts = MTLSizeMake(vrrGridPartitionsX, vrrGridPartitionsY, renderViewCount)
        for i in 0..<zoneCounts.depth {
            let layerDescriptor = MTLRasterizationRateLayerDescriptor(sampleCount: zoneCounts)
            // These are all hardcoded for 59/57 zones atm
            let innerWidthX = 11
            let innerWidthY = 11
            let innerShiftX = i == 0 ? 9 : -7
            let innerShiftY = 0
            let innerStartX = ((zoneCounts.width - innerWidthX) / 2) + innerShiftX
            let innerEndX = (innerStartX + innerWidthX)
            let innerStartY = ((zoneCounts.height - innerWidthY) / 2) + innerShiftY
            let innerEndY = (innerStartY + innerWidthY)
            let cutoffStartX = min(i == 0 ? 2 : 0, innerStartX)
            let cutoffEndX = min(i == 0 ? 0 : 2, zoneCounts.width-innerEndX)
            
            let innerVal: Float = 1.0
            let outerVal: Float = 1.0
            let edgeValStepY1: Float = outerVal/Float(innerStartY)
            let edgeValStepY2: Float = outerVal/Float(zoneCounts.height-innerEndY)
            let edgeValStepX1: Float = outerVal/Float(innerStartX-cutoffStartX)
            let edgeValStepX2: Float = outerVal/Float(zoneCounts.width-innerEndX-cutoffEndX)
            
            // Initialize Just In Case(tm)
            for row in 0..<zoneCounts.height {
                layerDescriptor.vertical[row] = 1.0/256.0
            }
            for column in 0..<zoneCounts.width {
                layerDescriptor.horizontal[column] = 1.0/256.0
            }
            
            // Vertical rates
            for row in 0..<innerStartY {
                layerDescriptor.vertical[row] = Float(row) * edgeValStepY1
            }
            for row in innerStartY..<innerEndY {
                layerDescriptor.vertical[row] = innerVal
            }
            for row in innerEndY..<zoneCounts.height {
                layerDescriptor.vertical[row] = Float(zoneCounts.height - row) * edgeValStepY2
            }
            
            // Horizontal Rates
            for column in cutoffStartX..<innerStartX {
                layerDescriptor.horizontal[column] = Float(column-cutoffStartX) * edgeValStepX1
            }
            for column in innerStartX..<innerEndX {
                layerDescriptor.horizontal[column] = innerVal
            }
            for column in innerEndX..<zoneCounts.width-cutoffEndX {
                layerDescriptor.horizontal[column] = Float((zoneCounts.width-cutoffEndX) - column) * edgeValStepX2
            }
            
            for row in 0..<zoneCounts.height {
                if layerDescriptor.vertical[row] <= 0.0 {
                    layerDescriptor.vertical[row] = 1.0 / 256.0
                }
                if layerDescriptor.vertical[row] >= 0.7 || layerDescriptor.vertical[row] <= 0.25 {
                    //layerDescriptor.vertical[row] = layerDescriptor.vertical[row] * layerDescriptor.vertical[row]
                }
                //print("row", row, layerDescriptor.vertical[row])
            }
            for column in 0..<zoneCounts.width {
                if layerDescriptor.horizontal[column] <= 0.0 {
                    layerDescriptor.horizontal[column] = 1.0 / 256.0
                }
                if layerDescriptor.horizontal[column] >= 0.5 || layerDescriptor.horizontal[column] <= 0.25 {
                    //layerDescriptor.horizontal[column] = layerDescriptor.horizontal[column] * layerDescriptor.horizontal[column]
                }
                //print("col", column, layerDescriptor.horizontal[column])
            }

#if false
            for row in 0..<zoneCounts.height {
                layerDescriptor.vertical[row] = DummyMetalRenderer.vrrParametersY[i][row]
                if layerDescriptor.vertical[row] >= 1.0 {
                    layerDescriptor.vertical[row] = 1.0 / 256.0
                }
            }
            for column in 0..<zoneCounts.width {
                layerDescriptor.horizontal[column] = DummyMetalRenderer.vrrParametersX[i][column]
                if layerDescriptor.horizontal[column] >= 1.0 {
                    layerDescriptor.horizontal[column] = 1.0 / 256.0
                }
            }
#endif
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
        currentOffscreenRenderWidth = layerWidth
        currentOffscreenRenderHeight = layerHeight
        
        // TODO: update mesh
        if meshResourceL == nil {
            meshResourceL = (try? createVRRMeshResource(0, vrrMap)) ?? MeshResource.generatePlane(width: 1.0, depth: 1.0)
        }
        if meshResourceR == nil {
            meshResourceR = (try? createVRRMeshResource(1, vrrMap)) ?? MeshResource.generatePlane(width: 1.0, depth: 1.0)
        }
        
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
            textureDesc.arrayLength = renderViewCount
            textureDesc.mipmapLevelCount = 1
            textureDesc.usage = [.renderTarget, .shaderRead]
            textureDesc.storageMode = .private
            
            let depthTextureDescriptor = MTLTextureDescriptor()
            depthTextureDescriptor.textureType = .type2DArray
            depthTextureDescriptor.pixelFormat = renderDepthFormat
            depthTextureDescriptor.width = currentRenderWidth
            depthTextureDescriptor.height = currentRenderHeight
            depthTextureDescriptor.depth = 1
            depthTextureDescriptor.arrayLength = renderViewCount
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
    
    func copyTextureToTexture(_ commandBuffer: MTLCommandBuffer, _ from: MTLTexture, _ to: MTLTexture, _ vrrMapBuffer: MTLBuffer) {
        var formatHDR = renderColorFormatDrawableHDR
        if #available(visionOS 2.0, *) {
            formatHDR = renderColorFormatDrawableVisionOS2HDR
        }

        // Create a render pass descriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()

        // Configure the render pass descriptor
        renderPassDescriptor.colorAttachments[0].texture = to // Set the destination texture as the render target
        renderPassDescriptor.colorAttachments[0].loadAction = .dontCare // .load for partial copy
        renderPassDescriptor.colorAttachments[0].storeAction = .store // Store the render target after rendering
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)

        // Create a render command encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render command encoder")
        }
        renderEncoder.label = "Copy Texture to Texture"
        renderEncoder.pushDebugGroup("Copy Texture to Texture")
        renderEncoder.setRenderPipelineState(to.pixelFormat == formatHDR ? passthroughPipelineStateHDR! : passthroughPipelineState!)
        renderEncoder.setFragmentTexture(from, index: 0)
        renderEncoder.setVertexBuffer(vrrMapBuffer, offset: 0, index: BufferIndex.VRR.rawValue)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.counterClockwise)

        renderEncoder.setVertexBuffer(copyVerticesBuffer, offset: 0, index: VertexAttribute.position.rawValue)

        for i in 0..<(vrrGridSizeY-1)*renderViewCount {
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: i*vrrGridSizeX*2, vertexCount: vrrGridSizeX*2)
        }

        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // DrawableQueue will always time out if it is not attached to a Material/Entity before it is
    // asked for. Also, we kinda do things weird and out of order to allow changing the resolution
    // at runtime, so we need to ensure this condition is met to avoid a deadlock.
    func ensureMaterialsBeforeDrawableDequeue(_ planeA_L: Entity, _ planeB_L: Entity, _ planeC_L: Entity, _ planeA_R: Entity, _ planeB_R: Entity, _ planeC_R: Entity) -> Bool {
        if !self.setPlaneMaterialA_L {
            if self.surfaceMaterialA_L != nil {
                if self.textureResourceA != nil && self.meshResourceL != nil{
                    try! self.surfaceMaterialA_L!.setParameter(
                        name: "texture",
                        value: .textureResource(self.textureResourceA!)
                    )
                    
                    let modelComponent = ModelComponent(mesh: self.meshResourceL!, materials: [self.surfaceMaterialA_L!])
                    planeA_L.components.set(modelComponent)
                    self.setPlaneMaterialA_L = true
                }
            }
        }
        if !self.setPlaneMaterialB_L {
            if self.surfaceMaterialB_L != nil {
                if self.textureResourceB != nil && self.meshResourceL != nil {
                    try! self.surfaceMaterialB_L!.setParameter(
                        name: "texture",
                        value: .textureResource(self.textureResourceB!)
                    )
                    
                    let modelComponent = ModelComponent(mesh: self.meshResourceL!, materials: [self.surfaceMaterialB_L!])
                    planeB_L.components.set(modelComponent)
                    self.setPlaneMaterialB_L = true
                }
            }
        }
        if !self.setPlaneMaterialC_L {
            if self.surfaceMaterialC_L != nil {
                if self.textureResourceC != nil && self.meshResourceL != nil {
                    try! self.surfaceMaterialC_L!.setParameter(
                        name: "texture",
                        value: .textureResource(self.textureResourceC!)
                    )
                    
                    let modelComponent = ModelComponent(mesh: self.meshResourceL!, materials: [self.surfaceMaterialC_L!])
                    planeC_L.components.set(modelComponent)
                    self.setPlaneMaterialC_L = true
                }
            }
        }
        
        if !self.setPlaneMaterialA_R {
            if self.surfaceMaterialA_R != nil {
                if self.textureResourceA != nil && self.meshResourceR != nil {
                    try! self.surfaceMaterialA_R!.setParameter(
                        name: "texture",
                        value: .textureResource(self.textureResourceA!)
                    )
                    
                    let modelComponent = ModelComponent(mesh: self.meshResourceR!, materials: [self.surfaceMaterialA_R!])
                    planeA_R.components.set(modelComponent)
                    self.setPlaneMaterialA_R = true
                }
            }
        }
        if !self.setPlaneMaterialB_R {
            if self.surfaceMaterialB_R != nil {
                if self.textureResourceB != nil && self.meshResourceR != nil {
                    try! self.surfaceMaterialB_R!.setParameter(
                        name: "texture",
                        value: .textureResource(self.textureResourceB!)
                    )
                    
                    let modelComponent = ModelComponent(mesh: self.meshResourceR!, materials: [self.surfaceMaterialB_R!])
                    planeB_R.components.set(modelComponent)
                    self.setPlaneMaterialB_R = true
                }
            }
        }
        if !self.setPlaneMaterialC_R {
            if self.surfaceMaterialC_R != nil {
                if self.textureResourceC != nil && self.meshResourceR != nil {
                    try! self.surfaceMaterialC_R!.setParameter(
                        name: "texture",
                        value: .textureResource(self.textureResourceC!)
                    )
                    
                    let modelComponent = ModelComponent(mesh: self.meshResourceR!, materials: [self.surfaceMaterialC_R!])
                    planeC_R.components.set(modelComponent)
                    self.setPlaneMaterialC_R = true
                }
            }
        }
        
        if !self.setPlaneMaterialA_L || !self.setPlaneMaterialB_L || !self.setPlaneMaterialC_L || !self.setPlaneMaterialA_R || !self.setPlaneMaterialB_R || !self.setPlaneMaterialC_R {
            return false
        }
        
        return true
    }

    func update(context: SceneUpdateContext) {
        let startUpdateTime = CACurrentMediaTime()
        
        // Check and see what RealityKit says its deltaTime is, unfortunately we're kinda locked to
        // whatever RK updates us at anyway
        let currentHz = 1.0 / context.deltaTime
        if context.deltaTime > 0.001 {
            currentHzAvg = (currentHzAvg * 0.95) + (currentHz * 0.05)
        }
        // Just in case(tm)
        if !currentHzAvg.isFinite || currentHzAvg.isNaN {
            currentHzAvg = 90.0
        }

        // RealityKit automatically calls this every frame for every scene.
        guard let planeA_L = context.scene.findEntity(named: "video_plane_a_L") else {
            return
        }
        guard let planeB_L = context.scene.findEntity(named: "video_plane_b_L") else {
            return
        }
        guard let planeC_L = context.scene.findEntity(named: "video_plane_c_L") else {
            return
        }
        guard let planeA_R = context.scene.findEntity(named: "video_plane_a_R") else {
            return
        }
        guard let planeB_R = context.scene.findEntity(named: "video_plane_b_R") else {
            return
        }
        guard let planeC_R = context.scene.findEntity(named: "video_plane_c_R") else {
            return
        }
        guard let backdrop = context.scene.findEntity(named: "backdrop_plane") as? ModelEntity else {
            return
        }

        guard let input_catcher = context.scene.findEntity(named: "input_catcher") as? ModelEntity else {
            return
        }
        
        input_catcher.isEnabled = !(WorldTracker.shared.eyeTrackingActive && !WorldTracker.shared.eyeIsMipmapMethod)
        
        let settings = ALVRClientApp.gStore.settings
        
        var commandBuffer: MTLCommandBuffer? = nil
        var frame: RKQueuedFrame? = nil
        
        if dynamicallyAdjustRenderScale && CACurrentMediaTime() - lastSubmit > 0.02 && lastSubmit - lastLastSubmit > 0.02 && CACurrentMediaTime() - lastFbChangeTime > 0.25 {
            currentRenderScale -= 0.25
        }
        
        // TODO: for some reason color format changes causes fps to drop to 45?
        if lastRenderScale != currentRenderScale || lastOffscreenRenderScale != currentOffscreenRenderScale || lastRenderColorFormat != currentRenderColorFormat {
            if meshHasVrr {
                currentRenderWidth = currentOffscreenRenderWidth
                currentRenderHeight = currentOffscreenRenderHeight
                currentRenderScale = Float(currentRenderWidth) / Float(renderWidth)
            }
            else {
                currentRenderWidth = Int(Double(renderWidth) * Double(currentRenderScale))
                currentRenderHeight = Int(Double(renderHeight) * Double(currentRenderScale))
            }
            
            currentOffscreenRenderWidth = Int(Double(renderWidth) * Double(currentOffscreenRenderScale))
            currentOffscreenRenderHeight = Int(Double(renderHeight) * Double(currentOffscreenRenderScale))
        
            // Recreate framebuffer
            self.drawableQueueA = DrawableWrapper(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*renderViewCount, usage: [.renderTarget], isBiplanar: meshHasVrr)
            self.textureResourceA = self.drawableQueueA!.makeTextureResource()
            self.drawableQueueB = DrawableWrapper(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*renderViewCount, usage: [.renderTarget], isBiplanar: meshHasVrr)
            self.textureResourceB = self.drawableQueueB!.makeTextureResource()
            self.drawableQueueC = DrawableWrapper(pixelFormat: currentDrawableRenderColorFormat, width: currentRenderWidth, height: currentRenderHeight*renderViewCount, usage: [.renderTarget], isBiplanar: meshHasVrr)
            self.textureResourceC = self.drawableQueueC!.makeTextureResource()
            
            self.setPlaneMaterialA_L = false
            self.setPlaneMaterialB_L = false

            self.setPlaneMaterialA_R = false
            self.setPlaneMaterialB_R = false
            self.setPlaneMaterialC_L = false
            self.setPlaneMaterialA_R = false
            self.setPlaneMaterialB_R = false
            self.setPlaneMaterialC_R = false
            
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
        
        if commandBuffer == nil {
            commandBuffer = commandQueue.makeCommandBuffer()
        }
        
        guard let commandBuffer = commandBuffer else {
            fatalError("Failed to create command buffer")
        }
        
        if !ensureMaterialsBeforeDrawableDequeue(planeA_L, planeB_L, planeC_L, planeA_R, planeB_R, planeC_R) {
            return
        }
    
        // TL;DR, we double buffer the *Entities* because visionOS 2.0 initially has a
        // bug which sometimes syncs LowLevelTextures even if the Entity hasn't had its
        // pose synced. To prevent drawing a new frame on an old pose, we hide the A/B
        // entity in such a way that it will only display if the pose is correct to the
        // frame we sent.
        rkFramesRendered += 1
        let whichRkFrame = rkFramesRendered % 3
    
        var drawable: MTLTexture? = nil
        if whichRkFrame == 0 {
            drawable = drawableQueueA?.nextTexture(commandBuffer: commandBuffer)
        }
        else if whichRkFrame == 1 {
            drawable = drawableQueueB?.nextTexture(commandBuffer: commandBuffer)
        }
        else if whichRkFrame == 2 {
            drawable = drawableQueueC?.nextTexture(commandBuffer: commandBuffer)
        }
        guard let drawable = drawable else {
            print("no drawable")
            rkFramesRendered -= 1 // Ensure whichRkFrame is still correct next time around
            return
        }
        
        objc_sync_enter(self.rkFramePoolLock)
        if !self.rkFramePool.isEmpty {
            let (texture, depthTexture, vrrBuffer) = self.rkFramePool.removeFirst()
            objc_sync_exit(self.rkFramePoolLock)
            let pair = self.renderFrame(drawableTexture: meshHasVrr ? drawable : texture, offscreenTexture: texture, depthTexture: depthTexture, vrrBuffer: vrrBuffer, commandBuffer: commandBuffer)
            frame = pair?.1
            if pair?.0 == nil {
                self.rkFramePool.append((texture, depthTexture, vrrBuffer))
                //print("no frame")
            }
        }
        objc_sync_exit(self.rkFramePoolLock)
        
        guard let frame = frame else {
            //print("no frame")
            
            // Late abort, keep visionOS happy and present the drawable even though it won't be visible
            if whichRkFrame == 0 {
                drawableQueueA!.present(commandBuffer: commandBuffer)
            }

            else {
                drawableQueueB!.present(commandBuffer: commandBuffer)
            }
            else if whichRkFrame == 1 {
                drawableQueueB!.present(commandBuffer: commandBuffer)
            }
            else if whichRkFrame == 2 {
                drawableQueueC!.present(commandBuffer: commandBuffer)
            }
            else {
                print("aaaaaaaaaa this switch needs extending")
            }
            rkFramesRendered -= 1 // Ensure whichRkFrame is still correct next time around
            
            return
        }

        // Alright no turning back now, we have everything we need.
        lastUpdateTime = CACurrentMediaTime()
        
        if lastSubmit == 0.0 {
            lastSubmit = CACurrentMediaTime() - visionProVsyncPrediction.vsyncDelta
            EventHandler.shared.handleHeadsetRemovedOrReentry()
            EventHandler.shared.handleHeadsetEntered()
            //EventHandler.shared.kickAlvr() // HACK: RealityKit kills the audio :/
        }

        var planeTransform_L = frame.transform * DummyMetalRenderer.renderViewTransforms[0]
        var planeTransform_R = frame.transform * DummyMetalRenderer.renderViewTransforms[1]
        let timestamp = frame.timestamp
        let texture = frame.texture
        let depthTexture = frame.depthTexture
        var vsyncTime = frame.vsyncTime
        let vrrBuffer = frame.vrrBuffer
        
        // HACK: keep the depths separate to avoid z fighting
        let rk_panel_depth_L = rk_panel_depth

        let rk_panel_depth_R = rk_panel_depth - 10
        let rk_panel_depth_R = rk_panel_depth - 10.0
        
        // TL;DR  each eye has asymmetric render tangents, but we can't scale each half individually so we
        // have to do some math to move the center of the plane where it should be.
        var scale_L = simd_float3(renderTangents[0].x + renderTangents[0].y, 1.0, renderTangents[0].z + renderTangents[0].w)
        scale_L *= rk_panel_depth_L
        var scale_R = simd_float3(renderTangents[1].x + renderTangents[1].y, 1.0, renderTangents[1].z + renderTangents[1].w)
        scale_R *= rk_panel_depth_R
        let diffLR_L = (renderTangents[0].x - renderTangents[0].y) * 0.5
        let diffUD_L = (renderTangents[0].z - renderTangents[0].w) * 0.5
        let diffLR_R = (renderTangents[1].x - renderTangents[1].y) * 0.5
        let diffUD_R = (renderTangents[1].z - renderTangents[1].w) * 0.5
        
        planeTransform_L.columns.3 -= planeTransform_L.columns.2 * rk_panel_depth_L
        planeTransform_L.columns.3 += planeTransform_L.columns.1 * rk_panel_depth_L * diffUD_L
        planeTransform_L.columns.3 -= planeTransform_L.columns.0 * rk_panel_depth_L * diffLR_L
        let orientation_L = simd_quatf(planeTransform_L) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
        let position_L = simd_float3(planeTransform_L.columns.3.x, planeTransform_L.columns.3.y, planeTransform_L.columns.3.z)
        
        planeTransform_R.columns.3 -= planeTransform_R.columns.2 * rk_panel_depth_R
        planeTransform_R.columns.3 += planeTransform_R.columns.1 * rk_panel_depth_R * diffUD_R
        planeTransform_R.columns.3 -= planeTransform_R.columns.0 * rk_panel_depth_R * diffLR_R
        let orientation_R = simd_quatf(planeTransform_R) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
        let position_R = simd_float3(planeTransform_R.columns.3.x, planeTransform_R.columns.3.y, planeTransform_R.columns.3.z)

#if !targetEnvironment(simulator)
        // Shouldn't be needed but just in case
        //texture.setPurgeableState(.nonVolatile)
        //depthTexture.setPurgeableState(.nonVolatile)
        //drawable!.texture.setPurgeableState(.nonVolatile)
        //vrrBuffer.setPurgeableState(.nonVolatile)
#endif
        if !meshHasVrr {
            copyTextureToTexture(commandBuffer, texture, drawable, vrrBuffer)
        }

        let submitTime = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            if EventHandler.shared.alvrInitialized /*&& EventHandler.shared.lastSubmittedTimestamp != timestamp*/ {
                vsyncTime = self.visionProVsyncPrediction.nextFrameTime
                
                let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
                let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
                //print("Finished:", queuedFrame!.timestamp)
                //print((vsyncTime - CACurrentMediaTime()) * 1000.0)
                //print("blit", (CACurrentMediaTime() - submitTime) * 1000.0)
                let lastRenderTime = (CACurrentMediaTime() - startUpdateTime) + self.visionProVsyncPrediction.vsyncDelta
                self.visionProVsyncPrediction.rkAvgRenderTime = (self.visionProVsyncPrediction.rkAvgRenderTime + lastRenderTime) * 0.5
                Task {
                    alvr_report_submit(timestamp, vsyncTimeNs &- currentTimeNs)
                }
                
                //print("blit roundtrip", CACurrentMediaTime() - self.lastUpdate, timestamp)
                self.lastUpdate = CACurrentMediaTime()
        
                EventHandler.shared.lastSubmittedTimestamp = timestamp
            }
        }
        
        // Update only the A/B/C panel we will be showing, and hide the other one
        planeA_L.isEnabled = false
        planeB_L.isEnabled = false
        planeC_L.isEnabled = false
        planeA_R.isEnabled = false
        planeB_R.isEnabled = false
        planeC_R.isEnabled = false
        
        var activePlane_L = planeA_L
        var activePlane_R = planeA_R
        if whichRkFrame == 1 {
            activePlane_L = planeB_L
            activePlane_R = planeB_R
        }
        else if whichRkFrame == 2 {
            activePlane_L = planeC_L
            activePlane_R = planeC_R
        }
        
        // left eye
        activePlane_L.position = position_L
        activePlane_L.orientation = orientation_L
        activePlane_L.scale = scale_L
        activePlane_L.isEnabled = true

        // right eye
        activePlane_R.position = position_R
        activePlane_R.orientation = orientation_R
        activePlane_R.scale = scale_R
        activePlane_R.isEnabled = true
        
        if settings.chromaKeyEnabled {
            backdrop.isEnabled = false
        }
        else {
            // Place giant plane 1m behind the video feed
            let backdrop_depth = (rk_panel_depth * 2.0)
            backdrop.position = simd_float3(0.0, 0.0, -backdrop_depth)
            backdrop.orientation = simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
            backdrop.scale = simd_float3(backdrop_depth * 4.0, backdrop_depth * 4.0, backdrop_depth * 4.0) // TODO: view tangents over 4.0? idk
            
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
        
        if whichRkFrame == 0 {
            drawableQueueA!.present(commandBuffer: commandBuffer)
        }
        else if whichRkFrame == 1 {
            drawableQueueB!.present(commandBuffer: commandBuffer)
        }
        else if whichRkFrame == 2 {
            drawableQueueC!.present(commandBuffer: commandBuffer)
        }

        else {
            print("aaaaaaaaaa this switch needs extending")
        }

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
        //print("totals", context.deltaTime, CACurrentMediaTime() - startUpdateTime)
    }
    
    // TODO: Share this with Renderer somehow
    @MainActor func renderFrame(drawableTexture: MTLTexture, offscreenTexture: MTLTexture, depthTexture: MTLTexture, vrrBuffer: MTLBuffer, commandBuffer: MTLCommandBuffer) -> (MTLCommandBuffer, RKQueuedFrame)? {
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

            Thread.sleep(forTimeInterval: 0.00001)
            
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
        

        if queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp {
            alvr_report_compositor_start(queuedFrame!.timestamp)
        }

        

        if queuedFrame != nil && !queuedFrame!.viewParamsValid /*&& EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp*/ {
            let nalViewsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
            defer { nalViewsPtr.deallocate() }
            alvr_report_compositor_start(queuedFrame!.timestamp, nalViewsPtr)

            queuedFrame = QueuedFrame(imageBuffer: queuedFrame!.imageBuffer, timestamp: queuedFrame!.timestamp, viewParamsValid: true, viewParams: [nalViewsPtr[0], nalViewsPtr[1]])
        }

        //print(queuedFrame, EventHandler.shared.alvrInitialized, streamingActiveForFrame)
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
            if let otherSettings = Settings.getAlvrSettings() {
                if otherSettings.video.encoderConfig.encodingGamma != renderer.encodingGamma {
                    needsPipelineRebuild = true
                }
                
                WorldTracker.shared.sendViewParams(viewTransforms:  EventHandler.shared.viewTransforms, viewFovs: EventHandler.shared.viewFovs)
            }
            
            let settings = ALVRClientApp.gStore.settings
            if EventHandler.shared.encodingGamma != renderer.encodingGamma {
                needsPipelineRebuild = true
            }
            
            /*if currentSetRenderScale != realityKitRenderScale {
                currentSetRenderScale = realityKitRenderScale
                if realityKitRenderScale <= 0.0 {
                    currentRenderScale = Float(renderScale)
                    dynamicallyAdjustRenderScale = true
                }
                else {
                    currentRenderScale = currentSetRenderScale
                    dynamicallyAdjustRenderScale = false
                }
            }*/

            if CACurrentMediaTime() - renderer.lastReconfigureTime > 1.0 && (settings.chromaKeyEnabled != renderer.chromaKeyEnabled || settings.chromaKeyColorR != renderer.chromaKeyColor.x || settings.chromaKeyColorG != renderer.chromaKeyColor.y || settings.chromaKeyColorB != renderer.chromaKeyColor.z || settings.chromaKeyDistRangeMin != renderer.chromaKeyLerpDistRange.x || settings.chromaKeyDistRangeMax != renderer.chromaKeyLerpDistRange.y) {
                renderer.lastReconfigureTime = CACurrentMediaTime()
                needsPipelineRebuild = true
            }
            
            if let videoFormat = EventHandler.shared.videoFormat {
                let nextYuvTransform = VideoHandler.getYUVTransformForVideoFormat(videoFormat)
                if nextYuvTransform != renderer.currentYuvTransform {
                    needsPipelineRebuild = true
                }
                renderer.currentYuvTransform = nextYuvTransform
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
        

        if queuedFrame != nil && !queuedFrame!.viewParamsValid {
            print("aaaaaaaa bad view params")
        }
        
        let vsyncTime = visionProVsyncPrediction.nextFrameTime
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        var deviceAnchor = framePreviouslyPredictedPose ?? matrix_identity_float4x4
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if EventHandler.shared.alvrInitialized {
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovs
            let viewTransforms = EventHandler.shared.viewTransforms
            
            let rkLatencyLimit = max(WorldTracker.maxPredictionRK, UInt64(visionProVsyncPrediction.vsyncLatency * Double(NSEC_PER_SEC))) //UInt64(Double(visionProVsyncPrediction.vsyncDelta * 6.0) * Double(NSEC_PER_SEC))
            let handAnchorLatencyLimit = WorldTracker.maxPrediction //UInt64(Double(visionProVsyncPrediction.vsyncDelta * 6.0) * Double(NSEC_PER_SEC))

            var targetTimestamp = vsyncTime - visionProVsyncPrediction.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), rkLatencyLimit)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime - visionProVsyncPrediction.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), handAnchorLatencyLimit)) / Double(NSEC_PER_SEC))
            var targetTimestamp = vsyncTime //- visionProVsyncPrediction.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), rkLatencyLimit)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime //- visionProVsyncPrediction.vsyncLatency + (Double(min(alvr_get_head_prediction_offset_ns(), handAnchorLatencyLimit)) / Double(NSEC_PER_SEC))
            
            // Make overlay look smooth (at the cost of timewarp)
            if renderer.fadeInOverlayAlpha > 0.0 || currentHzAvg < 65.0 {
                anchorTimestamp = vsyncTime + visionProVsyncPrediction.vsyncLatency
                targetTimestamp = vsyncTime + visionProVsyncPrediction.vsyncLatency
            }
            

            if !ALVRClientApp.gStore.settings.targetHandsAtRoundtripLatency {
                anchorTimestamp = vsyncTime - visionProVsyncPrediction.vsyncLatency
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
        
        // don't re-render reprojected frames
        /*if isReprojected && renderer.fadeInOverlayAlpha <= 0.0 {
            return nil
        }*/
        
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
        
        // TODO: why does this cause framerate to go down to 45?
        /*guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }*/

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

            if let encoder = renderer.beginRenderStreamingFrame(0, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: nil) {
                
                    
                renderer.renderStreamingFrame(0, commandBuffer: commandBuffer, renderEncoder: encoder, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
                
                renderer.endRenderStreamingFrame(renderEncoder: encoder)
            }
            
            
            renderer.renderStreamingFrameOverlays(0, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: nil)
            

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

            renderer.renderNothing(0, commandBuffer: commandBuffer, renderTargetColor: drawableTexture, renderTargetDepth: depthTexture, viewports: allViewports, viewTransforms: allViewTransforms, viewTangents: allViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor, drawable: nil)
            
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
        
        //print(submitTime - lastSubmit)
        
        lastLastSubmit = lastSubmit
        lastSubmit = submitTime
        
        let timestamp = queuedFrame?.timestamp ?? 0
        let rkQueuedFrame = RKQueuedFrame(texture: offscreenTexture, depthTexture: depthTexture, timestamp: timestamp, transform: planeTransform, vsyncTime: self.visionProVsyncPrediction.nextFrameTime, vrrMap: vrrMap, vrrBuffer: vrrBuffer)
        
        return (commandBuffer, rkQueuedFrame)
    }
}
