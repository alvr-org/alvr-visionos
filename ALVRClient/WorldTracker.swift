//
//  WorldTracker.swift
//  ALVRClient
//
//

import Foundation
import ARKit
import CompositorServices

class WorldTracker {
    static let shared = WorldTracker()
    
    let arSession: ARKitSession!
    let worldTracking: WorldTrackingProvider!
    let sceneReconstruction: SceneReconstructionProvider!
    let planeDetection: PlaneDetectionProvider!
    
    var deviceAnchorsLock = NSObject()
    var deviceAnchorsQueue = [UInt64]()
    var deviceAnchorsDictionary = [UInt64: simd_float4x4]()
    
    // Playspace and boundaries state
    var planeAnchors: [UUID: PlaneAnchor] = [:]
    var worldAnchors: [UUID: WorldAnchor] = [:]
    var worldTrackingAddedOriginAnchor = false
    var worldTrackingSteamVRTransform: simd_float4x4 = matrix_identity_float4x4
    var worldOriginAnchor: WorldAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
    var planeLock = NSObject()
    var lastUpdatedTs: TimeInterval = 0
    var crownPressCount = 0
    var sentPoses = 0
    
    static let maxPrediction = 30 * NSEC_PER_MSEC
    static let deviceIdHead = alvr_path_string_to_id("/user/head")
    
    init(arSession: ARKitSession = ARKitSession(), worldTracking: WorldTrackingProvider = WorldTrackingProvider(), sceneReconstruction: SceneReconstructionProvider = SceneReconstructionProvider(), planeDetection: PlaneDetectionProvider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])) {
        self.arSession = arSession
        self.worldTracking = worldTracking
        self.sceneReconstruction = sceneReconstruction
        self.planeDetection = planeDetection
        
        Task {
            await processReconstructionUpdates()
        }
        Task {
            await processPlaneUpdates()
        }
        Task {
            await processWorldTrackingUpdates()
        }
    }
    
    func initializeAr() async  {
    
        // Reset playspace state
        self.worldTrackingAddedOriginAnchor = false
        self.worldTrackingSteamVRTransform = matrix_identity_float4x4
        self.worldOriginAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
        self.lastUpdatedTs = 0
        self.crownPressCount = 0
        self.sentPoses = 0
        
        do {
            try await arSession.run([worldTracking, sceneReconstruction, planeDetection])
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }
    
    func processReconstructionUpdates() async {
        for await update in sceneReconstruction.anchorUpdates {
            //let meshAnchor = update.anchor
            //print(meshAnchor.id, meshAnchor.originFromAnchorTransform)
        }
    }
    
    func processPlaneUpdates() async {
        for await update in planeDetection.anchorUpdates {
            //print(update.event, update.anchor.classification, update.anchor.id, update.anchor.description)
            if update.anchor.classification == .window {
                // Skip planes that are windows.
                continue
            }
            switch update.event {
            case .added, .updated:
                updatePlane(update.anchor)
            case .removed:
                removePlane(update.anchor)
            }
            
        }
    }
    
    func anchorDistanceFromOrigin(anchor: WorldAnchor) -> Float {
        let pos = anchor.originFromAnchorTransform.columns.3
        return simd_distance(matrix_identity_float4x4.columns.3, pos)
    }
    
    // We have an origin anchor which we use to maintain SteamVR's positions
    // every time visionOS's centering changes.
    func processWorldTrackingUpdates() async {
        for await update in worldTracking.anchorUpdates {
            print(update.event, update.anchor.id, update.anchor.description, update.timestamp)
            
            switch update.event {
            case .added, .updated:
                worldAnchors[update.anchor.id] = update.anchor
                if !self.worldTrackingAddedOriginAnchor {
                    print("Early origin anchor?", anchorDistanceFromOrigin(anchor: update.anchor), "Current Origin,", self.worldOriginAnchor.id)
                    
                    // If we randomly get an anchor added within 3.5m, consider that our origin
                    if anchorDistanceFromOrigin(anchor: update.anchor) < 3.5 {
                        print("Set new origin!")
                        
                        // This has a (positive) minor side-effect: all redundant anchors within 3.5m will get cleaned up,
                        // though which anchor gets chosen will be arbitrary.
                        // But there should only be one anyway.
                        do {
                            try await worldTracking.removeAnchor(self.worldOriginAnchor)
                        }
                        catch {
                            // don't care
                        }
                    
                        worldOriginAnchor = update.anchor
                    }
                }
                
                if update.anchor.id == worldOriginAnchor.id {
                    self.worldOriginAnchor = update.anchor

                    let anchorTransform = update.anchor.originFromAnchorTransform
                    if GlobalSettings.shared.keepSteamVRCenter {
                        self.worldTrackingSteamVRTransform = anchorTransform
                    }
                    
                    // Crown-press shenanigans
                    if update.event == .updated {
                        let sinceLast = update.timestamp - lastUpdatedTs
                        if sinceLast < 3.0 && sinceLast > 0.5 {
                            crownPressCount += 1
                        }
                        else {
                            crownPressCount = 0
                        }
                        lastUpdatedTs = update.timestamp
                        
                        // Triple-press crown to purge nearby anchors and recenter
                        if crownPressCount >= 2 {
                            print("Reset world origin!")
                            
                            // Purge all existing world anchors within 3.5m
                            for anchorPurge in worldAnchors {
                                do {
                                    if anchorDistanceFromOrigin(anchor: update.anchor) < 3.5 {
                                        try await worldTracking.removeAnchor(anchorPurge.value)
                                    }
                                }
                                catch {
                                    // don't care
                                }
                                worldAnchors.removeValue(forKey: anchorPurge.key)
                            }
                    
                            self.worldOriginAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
                            if GlobalSettings.shared.keepSteamVRCenter {
                                self.worldTrackingSteamVRTransform = anchorTransform
                            }
                            
                            do {
                                try await worldTracking.addAnchor(self.worldOriginAnchor)
                            }
                            catch {
                                // don't care
                            }
                            
                            crownPressCount = 0
                        }
                    }
                }
                
            case .removed:
                break
            }
            
            
        }
    }
    
    func updatePlane(_ anchor: PlaneAnchor) {
        lockPlaneAnchors()
        planeAnchors[anchor.id] = anchor
        unlockPlaneAnchors()
    }

    func removePlane(_ anchor: PlaneAnchor) {
        lockPlaneAnchors()
        planeAnchors.removeValue(forKey: anchor.id)
        unlockPlaneAnchors()
    }
    
    func lockPlaneAnchors() {
        objc_sync_enter(planeLock)
    }
    
    func unlockPlaneAnchors() {
         objc_sync_exit(planeLock)
    }

    
    // TODO: figure out how stable Apple's predictions are into the future
    
    func sendTracking(targetTimestamp: Double) {
        let targetTimestamp = CACurrentMediaTime() + Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC)
        var targetTimestampWalkedBack = targetTimestamp
        var deviceAnchor:DeviceAnchor? = nil
        
        // Predict as far into the future as Apple will allow us.
        for i in 0...20 {
            deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: targetTimestampWalkedBack)
            if deviceAnchor != nil {
                break
            }
            targetTimestampWalkedBack -= (5/1000.0)
        }
        
        // Fallback.
        if deviceAnchor == nil {
            targetTimestampWalkedBack = CACurrentMediaTime()
            deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: targetTimestamp)
        }

        // Well, I'm out of ideas.
        guard let deviceAnchor = deviceAnchor else {
            return
        }
        
        // This is kinda fiddly: worldTracking doesn't have a way to get a list of existing anchors,
        // and addAnchor only works while fully immersed mode is fully running.
        // So we have to sandwich it in here where we know worldTracking is online.
        //
        // That aside, if we add an anchor at (0,0,0), we will get reports in processWorldTrackingUpdates()
        // every time the user recenters.
        if !self.worldTrackingAddedOriginAnchor && sentPoses > 300 {
            self.worldTrackingAddedOriginAnchor = true
            
            Task {
                do {
                    try await worldTracking.addAnchor(self.worldOriginAnchor)
                }
                catch {
                    // don't care
                }
            }
        }
        sentPoses += 1
        
        let targetTimestampNS = UInt64(targetTimestampWalkedBack * Double(NSEC_PER_SEC))
        
        deviceAnchorsQueue.append(targetTimestampNS)
        if deviceAnchorsQueue.count > 1000 {
            let val = deviceAnchorsQueue.removeFirst()
            deviceAnchorsDictionary.removeValue(forKey: val)
        }
        deviceAnchorsDictionary[targetTimestampNS] = deviceAnchor.originFromAnchorTransform
        
        // Don't move SteamVR center/bounds when the headset recenters
        // TODO: make an option
        var transform = self.worldTrackingSteamVRTransform.inverse * deviceAnchor.originFromAnchorTransform
        
        let orientation = simd_quaternion(transform)
        let position = transform.columns.3
        var trackingMotion = AlvrDeviceMotion(device_id: WorldTracker.deviceIdHead, orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z), linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0))
        let targetTimestampReqestedNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
        //print("asking for:", targetTimestampNS, "diff:", targetTimestampReqestedNS&-targetTimestampNS, "diff2:", targetTimestampNS&-lastRequestedTimestamp, "diff3:", targetTimestampNS&-currentTimeNs)
        EventHandler.shared.lastRequestedTimestamp = targetTimestampNS
        alvr_send_tracking(targetTimestampNS, &trackingMotion, 1)
    }
    
    func lookupDeviceAnchorFor(timestamp: UInt64) -> simd_float4x4? {
        return deviceAnchorsDictionary[timestamp]
    }
    
}
