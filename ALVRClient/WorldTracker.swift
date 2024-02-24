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
    var worldTrackingAddedAnchor = false
    var worldTrackingSteamVRTransform: simd_float4x4 = matrix_identity_float4x4
    var worldOriginAnchor: WorldAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
    
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
        self.worldTrackingAddedAnchor = false
        self.worldTrackingSteamVRTransform = matrix_identity_float4x4
        self.worldOriginAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
        
        do {
            try await arSession.run([worldTracking, sceneReconstruction, planeDetection])
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }
    
    func processReconstructionUpdates() async {
        for await update in sceneReconstruction.anchorUpdates {
            let meshAnchor = update.anchor
            //print(meshAnchor.id, meshAnchor.originFromAnchorTransform)
        }
    }
    
    func processPlaneUpdates() async {
        for await update in planeDetection.anchorUpdates {
            print(update.event, update.anchor.classification, update.anchor.id)
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
    
    // We have an origin anchor which we use to maintain SteamVR's positions
    // every time visionOS's centering changes.
    func processWorldTrackingUpdates() async {
        for await update in worldTracking.anchorUpdates {
            print(update.anchor.id, update.anchor.description, update.description, update.event)
            
            if update.anchor.id == worldOriginAnchor.id {
                let anchorTransform = update.anchor.originFromAnchorTransform
                if GlobalSettings.shared.keepSteamVRCenter {
                    self.worldTrackingSteamVRTransform = anchorTransform
                }
            }
            else {
                // TODO: how long do these anchors persist...? Could be useful.
                do {
                    try await worldTracking.removeAnchor(update.anchor)
                }
                catch {
                    // don't care
                }
            }
        }
    }
    
    func updatePlane(_ anchor: PlaneAnchor) {
        if planeAnchors[anchor.id] == nil {
            planeAnchors[anchor.id] = anchor
        }
    }

    func removePlane(_ anchor: PlaneAnchor) {
        planeAnchors.removeValue(forKey: anchor.id)
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
        if !self.worldTrackingAddedAnchor {
            self.worldTrackingAddedAnchor = true
            
            Task {
                do {
                    try await worldTracking.addAnchor(self.worldOriginAnchor)
                }
                catch {
                    // don't care
                }
            }
        }
        
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
