//
//  WorldTracker.swift
//

import Foundation
import ARKit
import CompositorServices

class WorldTracker {
    static let shared = WorldTracker()
    
    let arSession: ARKitSession!
    let worldTracking: WorldTrackingProvider!
    let handTracking: HandTrackingProvider!
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
    static let deviceIdLeftHand = alvr_path_string_to_id("/user/hand/left")
    static let deviceIdRightHand = alvr_path_string_to_id("/user/hand/right")
    static let appleHandToSteamVRIndex = [
        //eBone_Root
        "wrist": 1,                         //eBone_Wrist
        "thumbKnuckle": 2,                  //eBone_Thumb0
        "thumbIntermediateBase": 3,         //eBone_Thumb1
        "thumbIntermediateTip": 4,          //eBone_Thumb2
        "thumbTip": 5,                      //eBone_Thumb3
        "indexFingerMetacarpal": 6,         //eBone_IndexFinger0
        "indexFingerKnuckle": 7,            //eBone_IndexFinger1
        "indexFingerIntermediateBase": 8,   //eBone_IndexFinger2
        "indexFingerIntermediateTip": 9,    //eBone_IndexFinger3
        "indexFingerTip": 10,               //eBone_IndexFinger4
        "middleFingerMetacarpal": 11,       //eBone_MiddleFinger0
        "middleFingerKnuckle": 12,                //eBone_MiddleFinger1
        "middleFingerIntermediateBase": 13,       //eBone_MiddleFinger2
        "middleFingerIntermediateTip": 14,        //eBone_MiddleFinger3
        "middleFingerTip": 15,                    //eBone_MiddleFinger4
        "ringFingerMetacarpal": 16,         //eBone_RingFinger0
        "ringFingerKnuckle": 17,                  //eBone_RingFinger1
        "ringFingerIntermediateBase": 18,         //eBone_RingFinger2
        "ringFingerIntermediateTip": 19,          //eBone_RingFinger3
        "ringFingerTip": 20,                      //eBone_RingFinger4
        "littleFingerMetacarpal": 21,       //eBone_PinkyFinger0
        "littleFingerKnuckle": 22,                //eBone_PinkyFinger1
        "littleFingerIntermediateBase": 23,       //eBone_PinkyFinger2
        "littleFingerIntermediateTip": 24,        //eBone_PinkyFinger3
        "littleFingerTip": 25,                    //eBone_PinkyFinger4
        
        // 26-30 are aux bones and are done by ALVR
    ]
    
    init(arSession: ARKitSession = ARKitSession(), worldTracking: WorldTrackingProvider = WorldTrackingProvider(), handTracking: HandTrackingProvider = HandTrackingProvider(), sceneReconstruction: SceneReconstructionProvider = SceneReconstructionProvider(), planeDetection: PlaneDetectionProvider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])) {
        self.arSession = arSession
        self.worldTracking = worldTracking
        self.handTracking = handTracking
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
        Task {
            await processHandTrackingUpdates()
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
            try await arSession.run([worldTracking, handTracking, sceneReconstruction, planeDetection])
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
    
    func processHandTrackingUpdates() async {
        for await update in handTracking.anchorUpdates {
            switch update.event {
            case .added, .updated:
                break
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
    
    func appleHandOrientationToSteamVr(_ mat: simd_float4x4) -> simd_float4x4 {
        var ret = mat
        //var xBasis = [ret.columns.0[0], ret.columns.1[0], ret.columns.2[0]]
        //var yBasis = [ret.columns.0[1], ret.columns.1[1], ret.columns.2[1]]
        //var zBasis = [ret.columns.0[2], ret.columns.1[2], ret.columns.2[2]]
        
        /*ret.columns.0[0] = zBasis[0]
        ret.columns.1[0] = zBasis[1]
        ret.columns.2[0] = zBasis[2]
        ret.columns.0[2] = -xBasis[0]
        ret.columns.1[2] = -xBasis[1]
        ret.columns.2[2] = -xBasis[2]*/
        
        //ret.columns.0 = -ret.columns.0
        //ret.columns.1[0] = -xBasis[1]
        //ret.columns.2[0] = -xBasis[2]
        
        /*ret.columns.0[0] = xBasis[0]
        ret.columns.1[0] = xBasis[1]
        ret.columns.2[0] = xBasis[2]
        
        ret.columns.0[1] = yBasis[0]
        ret.columns.1[1] = yBasis[1]
        ret.columns.2[1] = yBasis[2]
        
        ret.columns.0[2] = -zBasis[0]
        ret.columns.1[2] = -zBasis[1]
        ret.columns.2[2] = -zBasis[2]*/
        
        // WHY DOESN'T THIS WORK?????
        //ret.columns.2 = -ret.columns.2
        
        for i in 0...3 {
            if ret.columns.0[i] == -0.0 {
                ret.columns.0[i] = 0.0
            }
            if ret.columns.1[i] == -0.0 {
                ret.columns.1[i] = 0.0
            }
            if ret.columns.2[i] == -0.0 {
                ret.columns.2[i] = 0.0
            }
        }
        
        //ret.columns.3[2] *= -1
        
        return ret
    }

    // idk unused atm
    func appleHandOrientationToSteamVrQuat(_ q: simd_quatf) -> simd_quatf {
        var ret = q.vector
        let q_vec = q.vector
        
        ret.x = q_vec.x
        ret.y = q_vec.y
        ret.z = -q_vec.z
        ret.w = -q_vec.w
        
        return simd_quatf(vector: ret)
    }

    func handAnchorToAlvrDeviceMotion(_ hand: HandAnchor) -> AlvrDeviceMotion {
        let device_id = hand.chirality == .left ? WorldTracker.deviceIdLeftHand : WorldTracker.deviceIdRightHand
        
        let transform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform
        let orientation = simd_quaternion(transform)
        let position = transform.columns.3
        let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
        return AlvrDeviceMotion(device_id: device_id, pose: pose, linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0))
    }
    
    func handAnchorToSkeleton(_ hand: HandAnchor) -> [AlvrPose]? {
        var ret: [AlvrPose] = []
        
        guard let skeleton = hand.handSkeleton else {
            return nil
        }
        let rootTransform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform
        let rootOrientation = simd_quaternion(rootTransform)
        let rootPosition = rootTransform.columns.3
        for i in 0...25 {
            let orientation = rootOrientation
            let position = rootPosition
            let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
            ret.append(pose)
        }
        
        
        // Apple has two additional joints: forearmWrist and forearmArm
        for joint in skeleton.allJoints {
            let steamVrIdx = WorldTracker.appleHandToSteamVRIndex[joint.name.description, default:-1]
            print(steamVrIdx, joint.name.description)
            if steamVrIdx < 0 || steamVrIdx >= 26 {
                continue
            }
            let transformRaw = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform * joint.anchorFromJointTransform
            let transform = transformRaw
            let orientation = simd_quaternion(appleHandOrientationToSteamVr(transform)) * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
            let position = transform.columns.3
            let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
            
            ret[steamVrIdx] = pose
            //print(i, skeleton.allJoints[i].name)
        }
        //ret[1] = ret[0] // eBone_Root = eBone_Wrist
        
        return ret
    }
    
    // TODO: figure out how stable Apple's predictions are into the future
    
    func sendTracking(targetTimestamp: Double) {
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
        let transform = self.worldTrackingSteamVRTransform.inverse * deviceAnchor.originFromAnchorTransform
        
        let orientation = simd_quaternion(transform)
        let position = transform.columns.3
        let headPose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
        let headTrackingMotion = AlvrDeviceMotion(device_id: WorldTracker.deviceIdHead, pose: headPose, linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0))
        var trackingMotions = [headTrackingMotion]
        var skeletonLeft:[AlvrPose]? = nil
        var skeletonRight:[AlvrPose]? = nil
        
        var skeletonLeftPtr:UnsafeMutablePointer<AlvrPose>? = nil
        var skeletonRightPtr:UnsafeMutablePointer<AlvrPose>? = nil
        
        let handPoses = handTracking.latestAnchors
        if let leftHand = handPoses.leftHand {
            if leftHand.isTracked {
                trackingMotions.append(handAnchorToAlvrDeviceMotion(leftHand))
                skeletonLeft = handAnchorToSkeleton(leftHand)
            }
        }
        if let rightHand = handPoses.rightHand {
            if rightHand.isTracked {
                trackingMotions.append(handAnchorToAlvrDeviceMotion(rightHand))
                skeletonRight = handAnchorToSkeleton(rightHand)
            }
        }
        if let skeletonLeft = skeletonLeft {
            if skeletonLeft.count == 26 {
                skeletonLeftPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 26)
                for i in 0...25 {
                    skeletonLeftPtr![i] = skeletonLeft[i]
                }
            }
        }
        if let skeletonRight = skeletonRight {
            if skeletonRight.count == 26 {
                skeletonRightPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 26)
                for i in 0...25 {
                    skeletonRightPtr![i] = skeletonRight[i]
                }
            }
        }
        
        //let targetTimestampReqestedNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        //let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
        //print("asking for:", targetTimestampNS, "diff:", targetTimestampReqestedNS&-targetTimestampNS, "diff2:", targetTimestampNS&-lastRequestedTimestamp, "diff3:", targetTimestampNS&-currentTimeNs)

        EventHandler.shared.lastRequestedTimestamp = targetTimestampNS
        alvr_send_tracking(targetTimestampNS, trackingMotions, UInt64(trackingMotions.count), [UnsafePointer(skeletonLeftPtr), UnsafePointer(skeletonRightPtr)], nil)
    }
    
    func lookupDeviceAnchorFor(timestamp: UInt64) -> simd_float4x4? {
        return deviceAnchorsDictionary[timestamp]
    }
    
}
