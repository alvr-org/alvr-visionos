//
//  RealityKitEyeTrackingSystem.swift
//
// This file is a fully self-contained and modular eye tracking addition
// which makes it easy to add eye tracking to any RealityKit environment with
// three lines added to a RealityKit View:
//
// await RealityKitEyeTrackingSystem.setup(content)
// MagicRealityKitEyeTrackingSystemComponent.registerComponent()
// RealityKitEyeTrackingSystem.registerSystem()
//
// Then, any Broadcast extension can read out the eye tracking data and send it
// back to this module via the CFNotificationCenter shift registers.
// (See ALVREyeBroadcast for more details on that)
//

import SwiftUI
import RealityKit
import QuartzCore

let eyeTrackWidth = Int(Float(renderWidth) * 2.5)
let eyeTrackHeight = Int(Float(renderHeight) * 2.5)

class NotificationShiftRegisterVar {
    var raw: UInt32 = 0
    var bits = 0
    var latchedRaw: UInt32 = 0
    var asFloat: Float = 0.0
    var asU32: UInt32 = 0
    var asS32: Int32 = 0
    
    var finalizeCallback: (()->Void)? = nil
    
    // Latch the raw value and finalize the different representations
    private func finalize() {
        self.latchedRaw = raw
        self.asFloat = Float(bitPattern: self.latchedRaw)
        self.asU32 = self.latchedRaw
        self.asS32 = Int32(bitPattern: self.latchedRaw)

        self.finalizeCallback?()
    }

    init(_ baseName: String) {
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let us = Unmanaged<NotificationShiftRegisterVar>.fromOpaque(observer!).takeUnretainedValue()
            us.raw = 0
            us.bits = 0
        }, baseName + "Start" as CFString, nil, .deliverImmediately)
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let us = Unmanaged<NotificationShiftRegisterVar>.fromOpaque(observer!).takeUnretainedValue()
            us.raw >>= 1
            us.raw |= 0
            us.bits += 1
            
            if us.bits >= 32 {
                us.finalize()
            }
        }, baseName + "0" as CFString, nil, .deliverImmediately)
        
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let us = Unmanaged<NotificationShiftRegisterVar>.fromOpaque(observer!).takeUnretainedValue()
            us.raw >>= 1
            us.raw |= 0x80000000
            us.bits += 1
            
            if us.bits >= 32 {
                us.finalize()
            }
        }, baseName + "1" as CFString, nil, .deliverImmediately)
    }
}

class NotificationManager: ObservableObject {
    @Published var message: String? = nil
    
    var lastHeartbeat = 0.0
    
    var xReg = NotificationShiftRegisterVar("EyeTrackingInfoX")
    var yReg = NotificationShiftRegisterVar("EyeTrackingInfoY")
    
    func updateSingleton() {
        WorldTracker.shared.eyeX = (self.xReg.asFloat - 0.5) * 1.0
        WorldTracker.shared.eyeY = ((1.0 - self.yReg.asFloat) - 0.5) * 1.0
    }

    init() {
        print("NotificationManager init")
        
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let us = Unmanaged<NotificationManager>.fromOpaque(observer!).takeUnretainedValue()
            us.lastHeartbeat = CACurrentMediaTime()
        }, "EyeTrackingInfoServerHeartbeat" as CFString, nil, .deliverImmediately)
        
        // Eye Y gets shifted last, so use it to sync with WorldTracker
        yReg.finalizeCallback = updateSingleton
    }
    
    func send(_ msg: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(msg as CFString), nil, nil, true)
    }

    deinit {
        print("NotificationManager deinit")
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque())
    }
}

struct MagicRealityKitEyeTrackingSystemComponent : Component {}

// Every WindowGroup technically counts as a Scene, which means
// we have to do Shenanigans to make sure that only the correct Scenes
// get associated with our per-frame system.
class RealityKitEyeTrackingSystem : System {
    static var howManyScenesExist = 0
    static var notificationManager = NotificationManager()
    var which = 0
    var timesTried = 0
    var s: RealityKitEyeTrackingSystemCorrectlyAssociated? = nil

    required init(scene: RealityKit.Scene) {
        which = RealityKitEyeTrackingSystem.howManyScenesExist
        RealityKitEyeTrackingSystem.howManyScenesExist += 1
    }
    
    static func setup(_ content: RealityViewContent) async {
        var hoverEffectTrackerMat: ShaderGraphMaterial? = nil
        
        if #available(visionOS 2.0, *) {
            hoverEffectTrackerMat = try! await ShaderGraphMaterial(
                named: "/Root/HoverEdgeTracker",
                from: "EyeTrackingMats.usda"
            )
        }
        else {
            hoverEffectTrackerMat = try! await ShaderGraphMaterial(
                named: "/Root/LeftEyeOnly",
                from: "EyeTrackingMats.usda"
            )
        }
        
        let leftEyeOnlyMat = try! await ShaderGraphMaterial(
            named: "/Root/LeftEyeOnly",
            from: "EyeTrackingMats.usda"
        )
            
        await MainActor.run { [hoverEffectTrackerMat] in
            let planeMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)

            let eyeXPlane = ModelEntity(mesh: planeMesh, materials: [leftEyeOnlyMat])
            eyeXPlane.name = "eye_x_plane"
            eyeXPlane.scale = simd_float3(0.0, 0.0, 0.0)
            eyeXPlane.components.set(MagicRealityKitEyeTrackingSystemComponent())
            
            let eyeYPlane = ModelEntity(mesh: planeMesh, materials: [leftEyeOnlyMat])
            eyeYPlane.name = "eye_y_plane"
            eyeYPlane.scale = simd_float3(0.0, 0.0, 0.0)
            eyeYPlane.components.set(MagicRealityKitEyeTrackingSystemComponent())

            let eye2Plane = ModelEntity(mesh: planeMesh, materials: [hoverEffectTrackerMat!])
            eye2Plane.name = "eye_2_plane"
            eye2Plane.scale = simd_float3(0.0, 0.0, 0.0)
            eye2Plane.components.set(MagicRealityKitEyeTrackingSystemComponent())
            eye2Plane.components.set(InputTargetComponent())
            eye2Plane.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: planeMesh)]))
                
            let anchor = AnchorEntity(.head)
            anchor.anchoring.trackingMode = .continuous
            anchor.name = "HeadAnchor"
            anchor.position = simd_float3(0.0, 0.0, 0.0)
            
            anchor.addChild(eyeXPlane)
            anchor.addChild(eyeYPlane)
            anchor.addChild(eye2Plane)
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
        let query = EntityQuery(where: .has(MagicRealityKitEyeTrackingSystemComponent.self))
        for _ in context.entities(matching: query, updatingSystemWhen: .rendering) {
            hasMagic = true
            break
        }
        
        if !hasMagic {
            timesTried += 1
            return
        }
        
        if s == nil {
            s = RealityKitEyeTrackingSystemCorrectlyAssociated(scene: context.scene)
        }
    }
}

class RealityKitEyeTrackingSystemCorrectlyAssociated : System {
    private(set) var surfaceMaterialX: ShaderGraphMaterial? = nil
    private(set) var surfaceMaterialY: ShaderGraphMaterial? = nil
    private var textureResourceX: TextureResource? = nil
    private var textureResourceY: TextureResource? = nil
    var lastHeartbeat = 0.0
    
    required init(scene: RealityFoundation.Scene) {
        let eyeColors = [
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.125, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0625, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0), // 7
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0), // 11, this is where 1920x1080 goes to
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0), // 15
        ]
        
        Task {
            self.textureResourceX = createTextureResourceWithColors(colors: eyeColors, baseSize: CGSize(width: eyeTrackWidth, height: 1))
            self.textureResourceY = createTextureResourceWithColors(colors: eyeColors, baseSize: CGSize(width: 1, height: eyeTrackHeight))
            
            self.surfaceMaterialX = try! await ShaderGraphMaterial(
                named: "/Root/LeftEyeOnly",
                from: "EyeTrackingMats.usda"
            )
            
            self.surfaceMaterialY = try! await ShaderGraphMaterial(
                named: "/Root/LeftEyeOnly",
                from: "EyeTrackingMats.usda"
            )
        
            try! self.surfaceMaterialX!.setParameter(
                name: "texture",
                value: .textureResource(self.textureResourceX!)
            )
            try! self.surfaceMaterialY!.setParameter(
                name: "texture",
                value: .textureResource(self.textureResourceY!)
            )
        }
    }
    
    func createTextureResourceWithColors(colors: [MTLClearColor], baseSize: CGSize) -> TextureResource? {
        var mipdata: [TextureResource.Contents.MipmapLevel] = []
        
        for level in 0..<colors.count {
            var size = CGSize(width: Int(baseSize.width) / (1<<level), height: Int(baseSize.height) / (1<<level))
            if size.width <= 0 {
                size.width = 1
            }
            if size.height <= 0 {
                size.height = 1
            }
            
            let color = colors[level]
            
            let r8 = UInt8(color.red * 255)
            let g8 = UInt8(color.green * 255)
            let b8 = UInt8(color.blue * 255)
            let a8 = UInt8(color.alpha * 255)
            
            var data8 = [UInt8](repeating: 0, count: 4*Int(size.width)*Int(size.height))
            for i in 0..<Int(size.width)*Int(size.height) {
                data8[(i*4)+0] = b8
                data8[(i*4)+1] = g8
                data8[(i*4)+2] = r8
                data8[(i*4)+3] = a8
            }
            let data = Data(data8)
            let mip = TextureResource.Contents.MipmapLevel.mip(data: data, bytesPerRow: 4*Int(size.width))
            
            mipdata.append(mip)
            
            if size.width == 1 && size.height == 1 {
                break
            }
        }
        
        do
        {
            return try TextureResource(
                dimensions: .dimensions(width: Int(baseSize.width), height: Int(baseSize.height)),
                format: .raw(pixelFormat: .bgra8Unorm_srgb),
                contents: .init(
                    mipmapLevels: mipdata
                )
            )
        }
        catch {
            return nil
        }
    }
    
    func update(context: SceneUpdateContext) {
        // RealityKit automatically calls this every frame for every scene.
        guard let eyeXPlane = context.scene.findEntity(named: "eye_x_plane") as? ModelEntity else {
            return
        }
        guard let eyeYPlane = context.scene.findEntity(named: "eye_y_plane") as? ModelEntity else {
            return
        }
        guard let eye2Plane = context.scene.findEntity(named: "eye_2_plane") as? ModelEntity else {
            return
        }
        
        // Leave eye tracking overlays and such off if we haven't heard from the server.
        if CACurrentMediaTime() - RealityKitEyeTrackingSystem.notificationManager.lastHeartbeat < 5.0 {
#if XCODE_BETA_16
            if #available(visionOS 2.0, *) {
                eye2Plane.components.set(HoverEffectComponent(.shader(.default)))
                if ALVRClientApp.gStore.settings.forceMipmapEyeTracking {
                    eyeXPlane.isEnabled = true
                    eyeYPlane.isEnabled = true
                    eye2Plane.isEnabled = false
                }
                else {
                    eyeXPlane.isEnabled = false
                    eyeYPlane.isEnabled = false
                    eye2Plane.isEnabled = true
                }
            }
            else {
                eyeXPlane.isEnabled = true
                eyeYPlane.isEnabled = true
                eye2Plane.isEnabled = false
            }
#else
            eyeXPlane.isEnabled = true
            eyeYPlane.isEnabled = true
            eye2Plane.isEnabled = false
#endif
            WorldTracker.shared.eyeTrackingActive = true
        }
        else {
            eyeXPlane.isEnabled = false
            eyeYPlane.isEnabled = false
            eye2Plane.isEnabled = false
            WorldTracker.shared.eyeTrackingActive = false
        }
        
        if !eyeXPlane.isEnabled && !eyeYPlane.isEnabled && !eye2Plane.isEnabled {
            return
        }
        
        if CACurrentMediaTime() - lastHeartbeat > 1.0 {
            if eye2Plane.isEnabled {
                RealityKitEyeTrackingSystem.notificationManager.send("EyeTrackingInfo_UseHoverEffectMethod")
            }
            else {
                WorldTracker.shared.eyeIsMipmapMethod = false
                RealityKitEyeTrackingSystem.notificationManager.send("EyeTrackingInfo_UseHoverEffectMethod")
            }
            else {
                WorldTracker.shared.eyeIsMipmapMethod = true
                RealityKitEyeTrackingSystem.notificationManager.send("EyeTrackingInfo_UseMipmapMethod")
            }
            lastHeartbeat = CACurrentMediaTime()
        }

        //
        // start eye track
        //
        
        let rk_eye_panel_depth = rk_panel_depth * 0.5
        let rk_eye_panel_depth: Float = rk_panel_depth * 0.5
        let transform = matrix_identity_float4x4 // frame.transform
        var planeTransformX = matrix_identity_float4x4// frame.transform
        planeTransformX.columns.3 -= transform.columns.2 * rk_eye_panel_depth
        planeTransformX.columns.3 += transform.columns.2 * rk_eye_panel_depth * 0.001
        planeTransformX.columns.3 += transform.columns.1 * rk_eye_panel_depth * (DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w) * 0.724
        
        var planeTransformY = transform
        planeTransformY.columns.3 -= transform.columns.2 * rk_eye_panel_depth
        planeTransformY.columns.3 += transform.columns.0 * rk_eye_panel_depth * (DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y) * 0.8125
        
        var planeTransform2 = transform
        planeTransform2.columns.3 -= transform.columns.2 * rk_eye_panel_depth
        
        var scaleX = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
        scaleX *= rk_eye_panel_depth
        scaleX.z = 5.0
        planeTransformX.columns.3 -= transform.columns.1 * rk_eye_panel_depth * (DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w) * 0.724
        planeTransformX.columns.3 += transform.columns.1 * rk_eye_panel_depth * (DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w) * 0.22625
        
        var scaleY = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
        scaleY *= rk_eye_panel_depth
        
        var scale2 = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
        var scale2 = simd_float3(max(DummyMetalRenderer.renderTangents[0].x, DummyMetalRenderer.renderTangents[1].x) + max(DummyMetalRenderer.renderTangents[0].y, DummyMetalRenderer.renderTangents[1].y), 1.0, max(DummyMetalRenderer.renderTangents[0].z, DummyMetalRenderer.renderTangents[1].z) + max(DummyMetalRenderer.renderTangents[0].w, DummyMetalRenderer.renderTangents[1].w))
        //var scale2 = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
        scale2 *= rk_eye_panel_depth

        let orientationXY = /*simd_quatf(frame.transform) **/ simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
        
        if let surfaceMaterial = surfaceMaterialX {
            eyeXPlane.model?.materials = [surfaceMaterial]
        }
        
        if let surfaceMaterial = surfaceMaterialY {
            eyeYPlane.model?.materials = [surfaceMaterial]
        }
        
        eyeXPlane.position = simd_float3(planeTransformX.columns.3.x, planeTransformX.columns.3.y, planeTransformX.columns.3.z)
        eyeXPlane.orientation = orientationXY
        eyeXPlane.scale = scaleX
        
        eyeYPlane.position = simd_float3(planeTransformY.columns.3.x, planeTransformY.columns.3.y, planeTransformY.columns.3.z)
        eyeYPlane.orientation = orientationXY
        eyeYPlane.scale = scaleY
        
        eye2Plane.position = simd_float3(planeTransform2.columns.3.x, planeTransform2.columns.3.y, planeTransform2.columns.3.z)
        eye2Plane.orientation = orientationXY
        eye2Plane.scale = scale2
            
        //
        // end eye track
        //
    }
}
