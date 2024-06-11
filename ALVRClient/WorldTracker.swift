//
//  WorldTracker.swift
//

import Foundation
import ARKit
import CompositorServices
import GameController
import CoreHaptics
import Spatial
import RealityKit

enum SteamVRJoints : Int {
    case root = 0                                  //eBone_Root
    case wrist = 1                                 //eBone_Wrist
    case thumbKnuckle = 2                          //eBone_Thumb0
    case thumbIntermediateBase = 3                 //eBone_Thumb1
    case thumbIntermediateTip = 4                  //eBone_Thumb2
    case thumbTip = 5                              //eBone_Thumb3
    case indexFingerMetacarpal = 6                 //eBone_IndexFinger0
    case indexFingerKnuckle = 7                    //eBone_IndexFinger1
    case indexFingerIntermediateBase = 8           //eBone_IndexFinger2
    case indexFingerIntermediateTip = 9            //eBone_IndexFinger3
    case indexFingerTip = 10                       //eBone_IndexFinger4
    case middleFingerMetacarpal = 11               //eBone_MiddleFinger0
    case middleFingerKnuckle = 12                  //eBone_MiddleFinger1
    case middleFingerIntermediateBase = 13         //eBone_MiddleFinger2
    case middleFingerIntermediateTip = 14          //eBone_MiddleFinger3
    case middleFingerTip = 15                      //eBone_MiddleFinger4
    case ringFingerMetacarpal = 16                 //eBone_RingFinger0
    case ringFingerKnuckle = 17                    //eBone_RingFinger1
    case ringFingerIntermediateBase = 18           //eBone_RingFinger2
    case ringFingerIntermediateTip = 19            //eBone_RingFinger3
    case ringFingerTip = 20                        //eBone_RingFinger4
    case littleFingerMetacarpal = 21               //eBone_PinkyFinger0
    case littleFingerKnuckle = 22                  //eBone_PinkyFinger1
    case littleFingerIntermediateBase = 23         //eBone_PinkyFinger2
    case littleFingerIntermediateTip = 24          //eBone_PinkyFinger3
    case littleFingerTip = 25                      //eBone_PinkyFinger4

    // SteamVR's 26-30 are aux bones and are done by ALVR
        
    // Special case: we want to stash these
    case forearmWrist = 26
    case forearmArm = 27
    
    case numberOfJoints = 28
}

extension AlvrQuat
{
	init(_ q: simd_quatf)
	{
		self.init(x: q.vector.x, y: q.vector.y, z: q.vector.z, w: q.vector.w)
	}
}

extension AlvrPose
{
    init() {
        self.init(simd_quatf(), simd_float3())
    }

    init(_ q: simd_quatf, _ p: simd_float3) {
        self.init(orientation: AlvrQuat(q), position: p.asArray3())
    }
    
    init(_ q: simd_quatf, _ p: simd_float4) {
        self.init(orientation: AlvrQuat(q), position: p.asArray3())
    }
}

extension simd_float3
{
    func asArray3() -> (Float, Float, Float)
    {
        return (self.x, self.y, self.z)
    }
    
    func asFloat4() -> simd_float4
    {
        return simd_float4(self.x, self.y, self.z, 0.0)
    }
}

extension simd_float4
{
    func asArray3() -> (Float, Float, Float)
    {
        return (self.x, self.y, self.z)
    }
    
    func asFloat3() -> simd_float3
    {
        return simd_float3(self.x, self.y, self.z)
    }
}

extension simd_quatd
{
    func toQuatf() -> simd_quatf
    {
        return simd_quatf(ix: Float(self.vector.x), iy: Float(self.vector.y), iz: Float(self.vector.z), r: Float(self.vector.w))
    }
}

func simd_look(at: SIMD3<Float>, up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> simd_float4x4 {
    let zAxis = normalize(at)
    let xAxis = normalize(cross(up, zAxis))
    let yAxis = normalize(cross(zAxis, xAxis))
    
    return simd_float4x4(
        simd_float4(xAxis, 0),
        simd_float4(yAxis, 0),
        simd_float4(zAxis, 0),
        simd_float4(0, 0, 0, 1)
    )
}

class WorldTracker {
    static let shared = WorldTracker()
    
    let arSession: ARKitSession!
    let worldTracking: WorldTrackingProvider!
    let handTracking: HandTrackingProvider!
    let sceneReconstruction: SceneReconstructionProvider!
    let planeDetection: PlaneDetectionProvider!
    
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
    
    // Hand tracking
    var lastHandsUpdatedTs: TimeInterval = 0
    var lastSentHandsTs: TimeInterval = 0
    var lastLeftHandPose: AlvrPose = AlvrPose()
    var lastRightHandPose: AlvrPose = AlvrPose()
    
    // Controller haptics
    var leftHapticsStart: TimeInterval = 0
    var leftHapticsEnd: TimeInterval = 0
    var leftHapticsFreq: Float = 0.0
    var leftHapticsAmplitude: Float = 0.0
    var leftEngine: CHHapticEngine? = nil
    
    var rightHapticsStart: TimeInterval = 0
    var rightHapticsEnd: TimeInterval = 0
    var rightHapticsFreq: Float = 0.0
    var rightHapticsAmplitude: Float = 0.0
    var rightEngine: CHHapticEngine? = nil
    
    static let maxPrediction = 30 * NSEC_PER_MSEC
    static let maxPredictionRK = 70 * NSEC_PER_MSEC
    static let deviceIdHead = alvr_path_string_to_id("/user/head")
    static let deviceIdLeftHand = alvr_path_string_to_id("/user/hand/left")
    static let deviceIdRightHand = alvr_path_string_to_id("/user/hand/right")
    static let deviceIdLeftForearm = alvr_path_string_to_id("/user/body/left_knee") // TODO: add a real forearm point?
    static let deviceIdRightForearm = alvr_path_string_to_id("/user/body/right_knee") // TODO: add a real forearm point?
    static let deviceIdLeftElbow = alvr_path_string_to_id("/user/body/left_elbow")
    static let deviceIdRightElbow = alvr_path_string_to_id("/user/body/right_elbow")
    static let deviceIdLeftFoot = alvr_path_string_to_id("/user/body/left_foot")
    static let deviceIdRightFoot = alvr_path_string_to_id("/user/body/right_foot")
    
    // Left hand inputs
    static let leftButtonA = alvr_path_string_to_id("/user/hand/left/input/a/click")
    static let leftButtonB = alvr_path_string_to_id("/user/hand/left/input/b/click")
    static let leftButtonX = alvr_path_string_to_id("/user/hand/left/input/x/click")
    static let leftButtonY = alvr_path_string_to_id("/user/hand/left/input/y/click")
    static let leftTriggerClick = alvr_path_string_to_id("/user/hand/left/input/trigger/click")
    static let leftTriggerValue = alvr_path_string_to_id("/user/hand/left/input/trigger/value")
    static let leftThumbstickX = alvr_path_string_to_id("/user/hand/left/input/thumbstick/x")
    static let leftThumbstickY = alvr_path_string_to_id("/user/hand/left/input/thumbstick/y")
    static let leftThumbstickClick = alvr_path_string_to_id("/user/hand/left/input/thumbstick/click")
    static let leftSystemClick = alvr_path_string_to_id("/user/hand/left/input/system/click")
    static let leftMenuClick = alvr_path_string_to_id("/user/hand/left/input/menu/click")
    static let leftSqueezeClick = alvr_path_string_to_id("/user/hand/left/input/squeeze/click")
    static let leftSqueezeValue = alvr_path_string_to_id("/user/hand/left/input/squeeze/value")
    static let leftSqueezeForce = alvr_path_string_to_id("/user/hand/left/input/squeeze/force")
    
    // Right hand inputs
    static let rightButtonA = alvr_path_string_to_id("/user/hand/right/input/a/click")
    static let rightButtonB = alvr_path_string_to_id("/user/hand/right/input/b/click")
    static let rightButtonX = alvr_path_string_to_id("/user/hand/right/input/x/click")
    static let rightButtonY = alvr_path_string_to_id("/user/hand/right/input/y/click")
    static let rightTriggerClick = alvr_path_string_to_id("/user/hand/right/input/trigger/click")
    static let rightTriggerValue = alvr_path_string_to_id("/user/hand/right/input/trigger/value")
    static let rightThumbstickX = alvr_path_string_to_id("/user/hand/right/input/thumbstick/x")
    static let rightThumbstickY = alvr_path_string_to_id("/user/hand/right/input/thumbstick/y")
    static let rightThumbstickClick = alvr_path_string_to_id("/user/hand/right/input/thumbstick/click")
    static let rightSystemClick = alvr_path_string_to_id("/user/hand/right/input/system/click")
    static let rightMenuClick = alvr_path_string_to_id("/user/hand/right/input/menu/click")
    static let rightSqueezeClick = alvr_path_string_to_id("/user/hand/right/input/squeeze/click")
    static let rightSqueezeValue = alvr_path_string_to_id("/user/hand/right/input/squeeze/value")
    static let rightSqueezeForce = alvr_path_string_to_id("/user/hand/right/input/squeeze/force")
    
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
        
        // SteamVR's 26-30 are aux bones and are done by ALVR
        
        // Special case: we want to stash these
        "forearmWrist": 26,
        "forearmArm": 27,
    ]
    static let leftHandOrientationCorrection = simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(-1.0, 0.0, 0.0)) * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, -1.0))
    static let rightHandOrientationCorrection = simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_float3(0.0, 0.0, -1.0)) * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
    static let leftForearmOrientationCorrection = simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, 1.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
    static let rightForearmOrientationCorrection = simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, 1.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(1.0, 0.0, 0.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(1.0, 0.0, 0.0))
    var testPosition = simd_float3(0.0, 0.0, 0.0)
    
    // Gaze rays -> controller emulation state
    var leftSelectionRayId = -1
    var leftSelectionRayOrigin = simd_float3(0.0, 0.0, 0.0)
    var leftSelectionRayDirection = simd_float3(0.0, 0.0, 0.0)
    var leftPinchStartPosition = simd_float3(0.0, 0.0, 0.0)
    var leftPinchCurrentPosition = simd_float3(0.0, 0.0, 0.0)
    var leftPinchStartAngle = simd_quatf()
    var leftPinchCurrentAngle = simd_quatf()
    var leftIsPinching = false
    var lastLeftIsPinching = false
    var leftPinchTrigger: Float = 0.0
    
    var rightSelectionRayId = -1
    var rightSelectionRayOrigin = simd_float3(0.0, 0.0, 0.0)
    var rightSelectionRayDirection = simd_float3(0.0, 0.0, 0.0)
    var rightPinchStartPosition = simd_float3(0.0, 0.0, 0.0)
    var rightPinchCurrentPosition = simd_float3(0.0, 0.0, 0.0)
    var rightPinchStartAngle = simd_quatf()
    var rightPinchCurrentAngle = simd_quatf()
    var rightIsPinching = false
    var lastRightIsPinching = false
    var rightPinchTrigger: Float = 0.0
    
    var leftPinchEyeDelta = simd_float3()
    var rightPinchEyeDelta = simd_float3()
    var averageViewTransformPositionalComponent = simd_float3()
    
    var pinchesAreFromRealityKit = false
    
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
    
    func resetPlayspace() {
        print("Reset playspace")
        // Reset playspace state
        self.worldTrackingAddedOriginAnchor = false
        self.worldTrackingSteamVRTransform = matrix_identity_float4x4
        self.worldOriginAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
        self.lastUpdatedTs = 0
        self.crownPressCount = 0
        self.sentPoses = 0
    }
    
    func initializeAr() async  {
        resetPlayspace()
        
        let authStatus = await arSession.requestAuthorization(for: [.handTracking, .worldSensing])
        
        var trackingList: [any DataProvider] = [worldTracking]
        if authStatus[.handTracking] == .allowed {
            trackingList.append(handTracking)
        }
        if authStatus[.worldSensing] == .allowed {
            trackingList.append(sceneReconstruction)
            trackingList.append(planeDetection)
        }
        
        do {
            try await arSession.run(trackingList)
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }
    
    func processReconstructionUpdates() async {
        for await _ in sceneReconstruction.anchorUpdates {
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
                    if anchorDistanceFromOrigin(anchor: update.anchor) < 3.5 && update.anchor.isTracked {
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
                        self.worldTrackingAddedOriginAnchor = true
                    }
                }
                
                if update.anchor.id == worldOriginAnchor.id {
                    self.worldOriginAnchor = update.anchor
                    
                    // This seems to happen when headset is removed, or on app close.
                    if !update.anchor.isTracked {
                        print("Headset removed?")
                        //EventHandler.shared.handleHeadsetRemoved()
                        //resetPlayspace()
                        continue
                    }

                    let anchorTransform = update.anchor.originFromAnchorTransform
                    if ALVRClientApp.gStore.settings.keepSteamVRCenter {
                        self.worldTrackingSteamVRTransform = anchorTransform
                    }
                    
                    // Crown-press shenanigans
                    if update.event == .updated {
                        let sinceLast = update.timestamp - lastUpdatedTs
                        if sinceLast < 1.5 && sinceLast > 0.5 {
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
                            self.worldTrackingAddedOriginAnchor = true
                            if ALVRClientApp.gStore.settings.keepSteamVRCenter {
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
                //print(update.timestamp - lastHandsUpdatedTs)
                lastHandsUpdatedTs = update.timestamp
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
    
    // Wrist-only pose
    func handAnchorToPoseFallback(_ hand: HandAnchor) -> AlvrPose {
        let transform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform
        var orientation = simd_quaternion(transform)
        if hand.chirality == .right {
            orientation = orientation * WorldTracker.rightHandOrientationCorrection
        }
        else {
            orientation = orientation * WorldTracker.leftHandOrientationCorrection
        }
        let position = transform.columns.3
        let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
        return pose
    }
    
    // Palm pose for controllers
    func handAnchorToPose(_ hand: HandAnchor) -> AlvrPose {
        // Fall back to wrist pose
        guard let skeleton = hand.handSkeleton else {
            return handAnchorToPoseFallback(hand)
        }
        
        let middleMetacarpal = skeleton.joint(.middleFingerMetacarpal)
        let middleProximal = skeleton.joint(.middleFingerKnuckle)
        let wrist = skeleton.joint(.wrist)
        let middleMetacarpalTransform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform * middleMetacarpal.anchorFromJointTransform
        let middleProximalTransform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform * middleProximal.anchorFromJointTransform
        let wristTransform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform * wrist.anchorFromJointTransform
        
        // Use the OpenXR definition of the palm, middle point between middle metacarpal and proximal.
        let middleMetacarpalPosition = middleMetacarpalTransform.columns.3
        let middleProximalPosition = middleProximalTransform.columns.3
        let position = (middleMetacarpalPosition + middleProximalPosition) / 2.0
        
        var orientation = simd_quaternion(wristTransform)
        if hand.chirality == .right {
            orientation = orientation * WorldTracker.rightHandOrientationCorrection
        }
        else {
            orientation = orientation * WorldTracker.leftHandOrientationCorrection
        }
        
        let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
        return pose
    }

    func handAnchorToAlvrDeviceMotion(_ hand: HandAnchor) -> AlvrDeviceMotion {
        let device_id = hand.chirality == .left ? WorldTracker.deviceIdLeftHand : WorldTracker.deviceIdRightHand
        let lastPose: AlvrPose = hand.chirality == .left ? lastLeftHandPose : lastRightHandPose
        let pose: AlvrPose = handAnchorToPose(hand)
        let dp = (pose.position.0 - lastPose.position.0, pose.position.1 - lastPose.position.1, pose.position.2 - lastPose.position.2)
        let dt = Float(lastHandsUpdatedTs - lastSentHandsTs)
        
        if !hand.isTracked {
            return AlvrDeviceMotion(device_id: device_id, pose: hand.chirality == .left ? lastLeftHandPose : lastRightHandPose, linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0))
        }
        
        if hand.chirality == .left {
            lastLeftHandPose = pose
        }
        else {
            lastRightHandPose = pose
        }
        
        return AlvrDeviceMotion(device_id: device_id, pose: pose, linear_velocity: (dp.0 / dt, dp.1 / dt, dp.2 / dt), angular_velocity: (0, 0, 0))
    }
    
    func quatDifference(_ a: simd_quatf, _ b: simd_quatf) -> simd_quatf {
        let delta = a * b.inverse
        return simd_slerp_longest(simd_quatf(), delta, 0.001)
    }
    
    func pinchToAlvrDeviceMotion(_ chirality: HandAnchor.Chirality) -> AlvrDeviceMotion {
        let isLeft = chirality == .left
        let device_id = isLeft ? WorldTracker.deviceIdLeftHand : WorldTracker.deviceIdRightHand
        
        let appleOrigin = isLeft ? leftSelectionRayOrigin : rightSelectionRayOrigin
        let appleDirection = isLeft ? leftSelectionRayDirection : rightSelectionRayDirection
        
        let origin = convertApplePositionToSteamVR(appleOrigin)
        let direction = simd_normalize(convertApplePositionToSteamVR(appleOrigin + appleDirection) - origin)
        let orient = simd_look(at: -direction)
        
        //let val = sin(Float(CACurrentMediaTime() * 0.0125)) + 1.0
        //let val2 = sin(Float(CACurrentMediaTime()))
        //let val3 = (((sin(Float(CACurrentMediaTime() * 0.025)) + 1.0) * 0.5) * 0.015)
        
        var pinchOffset = isLeft ? (leftPinchCurrentPosition - leftPinchStartPosition) : (rightPinchCurrentPosition - rightPinchStartPosition)
        
        //print(altitude)
        
        // Gathered these by oscillating the controller along the gaze ray, and then adjusting the
        // angles slightly with pinchOffset.y until the pointer stopped moving left/right and up/down.
        // Then I adjusted the positional offset with pinchOffset.xyz.
        let adjUpDown = simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_normalize(simd_float3(0.0, 1.0, 1.7389288)))
        let adjLeftRight = simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_normalize(simd_float3(0.06772318, 0.0, 1.0)))
        let adjPosition = simd_float3(0.0, isLeft ? -leftPinchEyeDelta.y : -rightPinchEyeDelta.y, 0.0)
        let q = simd_quatf(orient) * adjLeftRight * adjUpDown
        //pinchOffset = simd_float3()
        
        pinchOffset *= 3.5
        
        let pose: AlvrPose = AlvrPose(q, convertApplePositionToSteamVR(appleOrigin + (appleDirection * -0.5) + pinchOffset + adjPosition))
        
        return AlvrDeviceMotion(device_id: device_id, pose: pose, linear_velocity: (0,0,0), angular_velocity: (0, 0, 0))
    }
    
    func handAnchorToSkeleton(_ hand: HandAnchor) -> [AlvrPose]? {
        var ret: [AlvrPose] = []
        
        guard let skeleton = hand.handSkeleton else {
            return nil
        }
        let rootAlvrPose = handAnchorToPose(hand)
        let rootOrientation = simd_quatf(ix: rootAlvrPose.orientation.x, iy: rootAlvrPose.orientation.y, iz: rootAlvrPose.orientation.z, r: rootAlvrPose.orientation.w)
        let rootPosition = simd_float3(x: rootAlvrPose.position.0, y: rootAlvrPose.position.1, z: rootAlvrPose.position.2)
        let rootPose = AlvrPose(orientation: AlvrQuat(x: rootOrientation.vector.x, y: rootOrientation.vector.y, z: rootOrientation.vector.z, w: rootOrientation.vector.w), position: (rootPosition.x, rootPosition.y, rootPosition.z))
        for _ in 0...25+2 {
            ret.append(rootPose)
        }
        
        var wristOrientation = simd_quatf()
        var wristTransform = matrix_identity_float4x4
        
        // Apple has two additional joints: forearmWrist and forearmArm
        for joint in skeleton.allJoints {
            let steamVrIdx = WorldTracker.appleHandToSteamVRIndex[joint.name.description, default:-1]
            if steamVrIdx == -1 || steamVrIdx >= SteamVRJoints.numberOfJoints.rawValue {
                continue
            }
            let transformRaw = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform * joint.anchorFromJointTransform
            let transform = transformRaw
            var orientation = simd_quaternion(transform) * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
            
            if hand.chirality == .right {
                orientation = orientation * simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_float3(0.0, 0.0, -1.0))
            }
            else {
                orientation = orientation * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(-1.0, 0.0, 0.0))
            }

            // Make wrist/elbow trackers face outward
            if steamVrIdx == SteamVRJoints.forearmWrist.rawValue || steamVrIdx == SteamVRJoints.forearmArm.rawValue {
                if hand.chirality == .right {
                    orientation = orientation * WorldTracker.rightForearmOrientationCorrection
                }
                else {
                    orientation = orientation * WorldTracker.leftForearmOrientationCorrection
                }
            }
            
            if steamVrIdx == SteamVRJoints.forearmWrist.rawValue {
                wristOrientation = orientation
                wristTransform = transform
            }
            
            // HACK: Apple's elbows currently have the same orientation as their wrists, which VRChat's IK really doesn't like.
            if steamVrIdx == SteamVRJoints.forearmArm.rawValue {
                orientation = simd_quatf(ix: 0.0, iy: 0.0, iz: 0.0, r: 1.0)
            }
            
            // Lerp the elbows based on the wrists, with a mapping that goes from the wrist rotation 0-270deg
            // to the elbow 0-90deg.
            // (I'll be honest a lot of this math was trial and error, but it's very solid)
            /*if steamVrIdx == SteamVRJoints.forearmArm.rawValue {
                orientation = simd_quaternion(wristTransform)
                
                if hand.chirality == .right {
                    //orientation = orientation * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
                }
                else {
                    orientation = orientation * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
                }
                
                let rot = Rotation3D(orientation)
                let twistAxis = simd_float3(1.0, 0.0, 0.0)
                
                
                let (swing, twist) = rot.swingTwist(twistAxis: RotationAxis3D.init(x: twistAxis.x, y: twistAxis.y, z: twistAxis.z))
                
                var swingQuat = swing.quaternion.toQuatf()
                if hand.chirality == .right {
                    //swingQuat = swingQuat * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
                }
                else {
                    swingQuat = swingQuat * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
                }
                
                let twistEuler = twist.eulerAngles(order: .xyz).angles
                
                
                let val = (sin(Float(CACurrentMediaTime() * 1.5)) + 1.0) * 0.5
                if twistEuler.x < -Double.pi/2.0 /*|| twistEuler.x > (3.0*(Double.pi/4.0))*/ {
                    orientation = simd_slerp_longest(swingQuat, orientation, 0.333)
                }
                else {
                    orientation = simd_slerp(swingQuat, orientation, 0.333)
                }
                
                orientation = orientation * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
                
                /*if hand.chirality == .left {
                    print(hand.chirality == .right ? "right" : "left", twistEuler, val)
                }*/
            }*/

            var position = transform.columns.3
            // Move wrist/elbow slightly outward so that they appear to be on the surface of the arm,
            // instead of inside it.
            if steamVrIdx == SteamVRJoints.forearmWrist.rawValue || steamVrIdx == SteamVRJoints.forearmArm.rawValue {
                position += transform.columns.1 * (0.025 * (hand.chirality == .right ? 1.0 : -1.0))
            }
            
            let pose = AlvrPose(orientation, position)
            
            ret[steamVrIdx] = pose
        }
        
        return ret
    }
    
    func sendGamepadInputs() {
        func boolVal(_ val: Bool) -> AlvrButtonValue {
            return AlvrButtonValue(tag: ALVR_BUTTON_VALUE_BINARY, AlvrButtonValue.__Unnamed_union___Anonymous_field1(AlvrButtonValue.__Unnamed_union___Anonymous_field1.__Unnamed_struct___Anonymous_field0(binary: val)))
        }
        
        func scalarVal(_ val: Float) -> AlvrButtonValue {
            return AlvrButtonValue(tag: ALVR_BUTTON_VALUE_SCALAR, AlvrButtonValue.__Unnamed_union___Anonymous_field1(AlvrButtonValue.__Unnamed_union___Anonymous_field1.__Unnamed_struct___Anonymous_field1(scalar: val)))
        }
        
        // TODO: keyboards? trackpads?
        /*
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
              // bind to any key-up/-down
              keyboard.keyChangedHandler = {
                (keyboard, key, keyCode, pressed) in
                // compare buttons to GCKeyCode
                print(keyboard, key, keyCode, pressed)
              }
            }
         */
    
        //print(GCController.controllers())
        for controller in GCController.controllers() {
            let isLeft = (controller.vendorName == "Joy-Con (L)")
            var isBoth = false
            //print(controller.vendorName, controller.physicalInputProfile.elements, controller.physicalInputProfile.allButtons)
            if let gp = controller.extendedGamepad {
                isBoth = true
                gp.buttonA.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightButtonA, boolVal(pressed))
                }
                gp.buttonB.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightButtonB, boolVal(pressed))
                }
                gp.buttonX.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightSqueezeClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.rightSqueezeValue, scalarVal(value))
                    alvr_send_button(WorldTracker.rightSqueezeForce, scalarVal(value))
                }
                gp.buttonY.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightButtonY, boolVal(pressed))
                }
                
                // Kinda weird here, we're emulating Quest controllers bc we don't have a real input profile.
                gp.dpad.right.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftButtonY, boolVal(pressed))
                }
                gp.dpad.down.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftButtonX, boolVal(pressed))
                }
                gp.dpad.up.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftSqueezeClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.leftSqueezeValue, scalarVal(value))
                    alvr_send_button(WorldTracker.leftSqueezeForce, scalarVal(value))
                }
                gp.dpad.left.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftButtonX, boolVal(pressed))
                }
                
                // ZL/ZR -> Trigger
                gp.leftTrigger.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftTriggerClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(value))
                }
                
                gp.rightTrigger.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightTriggerClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(value))
                }
                
                // L/R -> Squeeze
                gp.leftShoulder.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftSqueezeClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.leftSqueezeValue, scalarVal(value))
                    alvr_send_button(WorldTracker.leftSqueezeForce, scalarVal(value))
                }
                gp.rightShoulder.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightSqueezeClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.rightSqueezeValue, scalarVal(value))
                    alvr_send_button(WorldTracker.rightSqueezeForce, scalarVal(value))
                }
                
                // Thumbsticks
                gp.leftThumbstick.valueChangedHandler = { (button, xValue, yValue) in
                    alvr_send_button(WorldTracker.leftThumbstickX, scalarVal(xValue))
                    alvr_send_button(WorldTracker.leftThumbstickY, scalarVal(yValue))
                }
                gp.leftThumbstickButton?.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftThumbstickClick, boolVal(pressed))
                }
                gp.rightThumbstick.valueChangedHandler = { (button, xValue, yValue) in
                    alvr_send_button(WorldTracker.rightThumbstickX, scalarVal(xValue))
                    alvr_send_button(WorldTracker.rightThumbstickY, scalarVal(yValue))
                }
                gp.rightThumbstickButton?.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightThumbstickClick, boolVal(pressed))
                }
                
                // System buttons of various varieties (whichever one actually hits)
                gp.buttonHome?.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightSystemClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.rightMenuClick, boolVal(pressed))
                }
                gp.buttonOptions?.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.leftSystemClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.leftMenuClick, boolVal(pressed))
                }
                gp.buttonMenu.pressedChangedHandler = { (button, value, pressed) in
                    alvr_send_button(WorldTracker.rightSystemClick, boolVal(pressed))
                    alvr_send_button(WorldTracker.rightMenuClick, boolVal(pressed))
                }
            }
            else {
                // At some point we might want to use this (for separate motion), but at the moment we cannot, because it is incomplete
                
                let b = controller.physicalInputProfile.buttons
                let a = controller.physicalInputProfile.axes
                if !isLeft {
                    alvr_send_button(WorldTracker.rightButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonY, boolVal(b["Button Y"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightSystemClick, boolVal(b["Button Options"]?.isPressed ?? false))
                }
                else {
                    alvr_send_button(WorldTracker.leftButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonY, boolVal(b["Button Y"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftSystemClick, boolVal(b["Button Options"]?.isPressed ?? false))
                    
                }
            }
            
            // TODO: Frequency
            if let haptics = controller.haptics {
            
                if (isLeft || isBoth) {
                    if leftEngine == nil {
                        leftEngine = haptics.createEngine(withLocality: GCHapticsLocality.leftHandle)
                        
                        if leftEngine == nil {
                            for locality in haptics.supportedLocalities {
                                if (locality.rawValue as String).contains("(L)") {
                                    leftEngine = haptics.createEngine(withLocality: locality)
                                }
                            }
                        }
                        
                        if leftEngine == nil {
                            leftEngine = haptics.createEngine(withLocality: GCHapticsLocality.all)
                        }
                        
                        if leftEngine != nil {
                            do {
                                try leftEngine!.start()
                            } catch {
                                print("Error starting left engine: \(error)")
                            }
                        }
                    }
    
                    if let engine = leftEngine {
                        //print("haptic!")
                        var duration = leftHapticsEnd - leftHapticsStart
                        var amplitude = leftHapticsAmplitude
                        if duration < 0 {
                            print("Skip haptic, negative duration?", duration)
                            amplitude = 0.0
                            duration = 0.032
                        }
                        if leftHapticsEnd < CACurrentMediaTime() {
                            amplitude = 0.0
                            duration = 0.032
                            //print("Skip haptic, already over")
                        }
                        if duration > 0.5 {
                            duration = 0.5
                        }
                        if duration < 0.032 {
                            duration = 0.032
                        }
                        do {
                            let hapticPattern = try CHHapticPattern(events: [
                                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
                                    CHHapticEventParameter(parameterID: .hapticIntensity, value: amplitude)
                                ], relativeTime: 0, duration: duration)
                            ], parameters: [])
                        
                            try engine.makePlayer(with: hapticPattern).start(atTime: engine.currentTime)
                        } catch {
                            print("Error playing pattern: \(error)")
                            
                            leftEngine!.stop()
                            leftEngine = nil
                        }
                    }
                }
                
                if (!isLeft || isBoth) {
                    if rightEngine == nil {
                        rightEngine = haptics.createEngine(withLocality: GCHapticsLocality.rightHandle)
                        
                        if rightEngine == nil {
                            for locality in haptics.supportedLocalities {
                                if (locality.rawValue as String).contains("(r)") {
                                    rightEngine = haptics.createEngine(withLocality: locality)
                                }
                            }
                        }
                        
                        if rightEngine == nil {
                            rightEngine = haptics.createEngine(withLocality: GCHapticsLocality.all)
                        }
                        
                        if rightEngine != nil {
                            do {
                                try rightEngine!.start()
                            } catch {
                                print("Error starting right engine: \(error)")
                            }
                        }
                    }
    
                    if let engine = rightEngine {
                        //print("haptic!")
                        var duration = rightHapticsEnd - rightHapticsStart
                        var amplitude = rightHapticsAmplitude
                        if duration < 0 {
                            print("Skip haptic, negative duration?", duration)
                            amplitude = 0.0
                            duration = 0.032
                        }
                        if rightHapticsEnd < CACurrentMediaTime() {
                            amplitude = 0.0
                            duration = 0.032
                            //print("Skip haptic, already over")
                        }
                        if duration > 0.5 {
                            duration = 0.5
                        }
                        if duration < 0.032 {
                            duration = 0.032
                        }
                        do {
                            let hapticPattern = try CHHapticPattern(events: [
                                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
                                    CHHapticEventParameter(parameterID: .hapticIntensity, value: amplitude)
                                ], relativeTime: 0, duration: duration)
                            ], parameters: [])
                        
                            try engine.makePlayer(with: hapticPattern).start(atTime: engine.currentTime)
                        } catch {
                            print("Error playing pattern: \(error)")
                            
                            rightEngine!.stop()
                            rightEngine = nil
                        }
                    }
                }
            }
            
            // TODO motion fusion
            /*controller.motion?.valueChangedHandler = { (motion: GCMotion)->() in
              print(motion.acceleration, motion.rotationRate)
            }
            controller.motion?.sensorsActive = true*/
        }
    }
    
    var lastSentTime = 0.0
    
    // TODO: figure out how stable Apple's predictions are into the future
    // targetTimestamp: The timestamp of the pose we will send to ALVR--capped by how far we can predict forward.
    // realTargetTimestamp: The timestamp we tell ALVR, which always includes the full round-trip prediction.
    func sendTracking(viewTransforms: [simd_float4x4], viewFovs: [AlvrFov], targetTimestamp: Double, reportedTargetTimestamp: Double, anchorTimestamp: Double, delay: Double) {
        var targetTimestampWalkedBack = targetTimestamp
        var deviceAnchor:DeviceAnchor? = nil
        
        // Predict as far into the future as Apple will allow us.
        for _ in 0...20 {
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
            print("Failed to get device anchor for future prediction!!")
            // Prevent audio crackling issues
            if sentPoses > 30 {
                EventHandler.shared.handleHeadsetRemoved()
            }
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
        
        //let targetTimestampNS = UInt64(targetTimestampWalkedBack * Double(NSEC_PER_SEC))
        let reportedTargetTimestampNS = UInt64(reportedTargetTimestamp * Double(NSEC_PER_SEC))
        
        let headPositionApple = deviceAnchor.originFromAnchorTransform.columns.3.asFloat3()
        
        
        // HACK: The selection ray origin is slightly off (especially for Metal).
        // I think they subtracted the view transform from the pinch origin twice?
        // Added instead of subtracted? idk, it's something weird.
        //
        // Example: delta.y = 0.020709395
        // Real head y = 1.1004653
        // Pinch origin y = 1.0797559
        // y which lines up the ray correctly = 1.059214
        if leftIsPinching && leftSelectionRayOrigin != simd_float3() && leftPinchStartPosition == leftPinchCurrentPosition {
            leftPinchEyeDelta = headPositionApple - leftSelectionRayOrigin
            leftPinchEyeDelta -= averageViewTransformPositionalComponent
            if !pinchesAreFromRealityKit {
                leftPinchEyeDelta -= averageViewTransformPositionalComponent
                if #available(visionOS 2.0, *) {
                    leftPinchEyeDelta += averageViewTransformPositionalComponent
                }
            }
            //print("left pinch eye delta", leftPinchEyeDelta)
        }
        if rightIsPinching && rightSelectionRayOrigin != simd_float3() && rightPinchStartPosition == rightPinchCurrentPosition {
            rightPinchEyeDelta = headPositionApple - rightSelectionRayOrigin
            rightPinchEyeDelta -= averageViewTransformPositionalComponent
            if !pinchesAreFromRealityKit {
                rightPinchEyeDelta -= averageViewTransformPositionalComponent
                if #available(visionOS 2.0, *) {
                    rightPinchEyeDelta += averageViewTransformPositionalComponent
                }
            }
            //print("right pinch eye delta", rightPinchEyeDelta)
        }

        // Don't move SteamVR center/bounds when the headset recenters
        let transform = self.worldTrackingSteamVRTransform.inverse * deviceAnchor.originFromAnchorTransform
        let leftTransform = transform * viewTransforms[0]
        let rightTransform = transform * viewTransforms[1]
        
        let leftOrientation = simd_quaternion(leftTransform)
        let leftPosition = leftTransform.columns.3
        let leftPose = AlvrPose(leftOrientation, leftPosition)
        let rightOrientation = simd_quaternion(rightTransform)
        let rightPosition = rightTransform.columns.3
        let rightPose = AlvrPose(rightOrientation, rightPosition)
        
        var trackingMotions:[AlvrDeviceMotion] = []
        var skeletonLeft:[AlvrPose]? = nil
        var skeletonRight:[AlvrPose]? = nil
        
        var skeletonLeftPtr:UnsafeMutablePointer<AlvrPose>? = nil
        var skeletonRightPtr:UnsafeMutablePointer<AlvrPose>? = nil
        
        var handPoses = handTracking.latestAnchors
        if #available(visionOS 2.0, *) {
            handPoses = handTracking.handAnchors(at: anchorTimestamp)
        }
        if let leftHand = handPoses.leftHand {
            if !(ALVRClientApp.gStore.settings.emulatedPinchInteractions && (leftIsPinching || leftPinchTrigger > 0.0)) /*&& lastHandsUpdatedTs != lastSentHandsTs*/ {
                if leftHand.isTracked {
                    trackingMotions.append(handAnchorToAlvrDeviceMotion(leftHand))
                    skeletonLeft = handAnchorToSkeleton(leftHand)
                }
                else {
                    trackingMotions.append(handAnchorToAlvrDeviceMotion(leftHand))
                }
            }
        }
        if let rightHand = handPoses.rightHand {
            if !(ALVRClientApp.gStore.settings.emulatedPinchInteractions && (rightIsPinching || rightPinchTrigger > 0.0)) /*&& lastHandsUpdatedTs != lastSentHandsTs*/ {
                if rightHand.isTracked {
                    trackingMotions.append(handAnchorToAlvrDeviceMotion(rightHand))
                    skeletonRight = handAnchorToSkeleton(rightHand)
                }
                else {
                    trackingMotions.append(handAnchorToAlvrDeviceMotion(rightHand))
                }
            }
        }
        if let skeletonLeft = skeletonLeft {
            if skeletonLeft.count >= SteamVRJoints.numberOfJoints.rawValue {
                skeletonLeftPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 26)
                for i in 0...25 {
                    skeletonLeftPtr![i] = skeletonLeft[i]
                }
                
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftForearm, pose: skeletonLeft[SteamVRJoints.forearmWrist.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftElbow, pose: skeletonLeft[SteamVRJoints.forearmArm.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
            }
        }
        if let skeletonRight = skeletonRight {
            if skeletonRight.count >= SteamVRJoints.numberOfJoints.rawValue {
                skeletonRightPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 26)
                for i in 0...25 {
                    skeletonRightPtr![i] = skeletonRight[i]
                }
                
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdRightForearm, pose: skeletonRight[SteamVRJoints.forearmWrist.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdRightElbow, pose: skeletonRight[SteamVRJoints.forearmArm.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
            }
        }
        
        func boolVal(_ val: Bool) -> AlvrButtonValue {
            return AlvrButtonValue(tag: ALVR_BUTTON_VALUE_BINARY, AlvrButtonValue.__Unnamed_union___Anonymous_field1(AlvrButtonValue.__Unnamed_union___Anonymous_field1.__Unnamed_struct___Anonymous_field0(binary: val)))
        }
        
        func scalarVal(_ val: Float) -> AlvrButtonValue {
            return AlvrButtonValue(tag: ALVR_BUTTON_VALUE_SCALAR, AlvrButtonValue.__Unnamed_union___Anonymous_field1(AlvrButtonValue.__Unnamed_union___Anonymous_field1.__Unnamed_struct___Anonymous_field1(scalar: val)))
        }
        
        if ALVRClientApp.gStore.settings.emulatedPinchInteractions {
            // Menu press with two pinches
            // (have to override triggers to prevent screenshot send)
            if (rightIsPinching && leftIsPinching) {
                alvr_send_button(WorldTracker.leftMenuClick, boolVal(true))
                alvr_send_button(WorldTracker.leftTriggerClick, boolVal(false))
                alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(0.0))
                alvr_send_button(WorldTracker.rightTriggerClick, boolVal(false))
                alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(0.0))
                
                trackingMotions.append(pinchToAlvrDeviceMotion(.left))
                trackingMotions.append(pinchToAlvrDeviceMotion(.right))
            }
            else {
                if leftIsPinching {
                    trackingMotions.append(pinchToAlvrDeviceMotion(.left))
                    alvr_send_button(WorldTracker.leftTriggerClick, boolVal(leftPinchTrigger > 0.7))
                    alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(leftPinchTrigger))
                    leftPinchTrigger += 0.1
                    if leftPinchTrigger > 1.0 {
                        leftPinchTrigger = 1.0
                    }
                }
                else if !leftIsPinching && leftPinchTrigger > 0.0 {
                    alvr_send_button(WorldTracker.leftTriggerClick, boolVal(leftPinchTrigger > 0.7))
                    alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(leftPinchTrigger))
                    leftPinchTrigger -= 0.1
                    if leftPinchTrigger <= 0.1 {
                        WorldTracker.shared.leftSelectionRayOrigin = simd_float3()
                        WorldTracker.shared.leftSelectionRayDirection = simd_float3()
                    }
                    if leftPinchTrigger < 0.0 {
                        leftPinchTrigger = 0.0
                    }
                }
                
                if rightIsPinching {
                    trackingMotions.append(pinchToAlvrDeviceMotion(.right))
                    alvr_send_button(WorldTracker.rightTriggerClick, boolVal(rightPinchTrigger > 0.7))
                    alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(rightPinchTrigger))
                    rightPinchTrigger += 0.1
                    if rightPinchTrigger > 1.0 {
                        rightPinchTrigger = 1.0
                    }
                }
                else if !rightIsPinching && rightPinchTrigger > 0.0 {
                    alvr_send_button(WorldTracker.rightTriggerClick, boolVal(rightPinchTrigger > 0.7))
                    alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(rightPinchTrigger))
                    rightPinchTrigger -= 0.1
                    if rightPinchTrigger <= 0.1 {
                        WorldTracker.shared.rightSelectionRayOrigin = simd_float3()
                        WorldTracker.shared.rightSelectionRayDirection = simd_float3()
                    }
                    if rightPinchTrigger < 0.0 {
                        rightPinchTrigger = 0.0
                    }
                }
                alvr_send_button(WorldTracker.leftMenuClick, boolVal(false))
            }
            
            lastLeftIsPinching = leftIsPinching
            lastRightIsPinching = rightIsPinching
        }
        
        // selection ray tests, replaces left forearm
        /*var testPoseApple = matrix_identity_float4x4
        testPoseApple.columns.3 = simd_float4(self.testPosition.x, self.testPosition.y, self.testPosition.z, 1.0)
        testPoseApple = self.worldTrackingSteamVRTransform.inverse * testPoseApple
        let testPosApple = testPoseApple.columns.3
        let testPose = AlvrPose(orientation: AlvrQuat(x: 0.0, y: 0.0, z: 0.0, w: 1.0), position: (testPosApple.x, testPosApple.y, testPosApple.z))
        trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftForearm, pose: testPose, linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))*/
        
        //let targetTimestampReqestedNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        //let currentTimeNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
        //print("asking for:", targetTimestampNS, "diff:", targetTimestampReqestedNS&-targetTimestampNS, "diff2:", targetTimestampNS&-EventHandler.shared.lastRequestedTimestamp, "diff3:", targetTimestampNS&-currentTimeNs)
        
        let viewFovsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        viewFovsPtr[0] = AlvrViewParams(pose: leftPose, fov: viewFovs[0])
        viewFovsPtr[1] = AlvrViewParams(pose: rightPose, fov: viewFovs[1])

        //print((CACurrentMediaTime() - lastSentTime) * 1000.0)
        lastSentTime = CACurrentMediaTime()
        EventHandler.shared.lastRequestedTimestamp = reportedTargetTimestampNS
        lastSentHandsTs = lastHandsUpdatedTs
        
        if delay == 0.0 {
            sendGamepadInputs()
        }

        Thread {
            //Thread.sleep(forTimeInterval: delay)
            alvr_send_tracking(reportedTargetTimestampNS, UnsafePointer(viewFovsPtr), trackingMotions, UInt64(trackingMotions.count), [UnsafePointer(skeletonLeftPtr), UnsafePointer(skeletonRightPtr)], nil)
            
            viewFovsPtr.deallocate()
            skeletonLeftPtr?.deallocate()
            skeletonRightPtr?.deallocate()
        }.start()
    }
    
    // We want video frames ASAP, so we send a fake view pose/FOVs to keep the frames coming
    // until we have access to real values
    func sendFakeTracking(viewFovs: [AlvrFov], targetTimestamp: Double) {
        let dummyPose = AlvrPose()
        let targetTimestampNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        
        let viewFovsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        viewFovsPtr[0] = AlvrViewParams(pose: dummyPose, fov: viewFovs[0])
        viewFovsPtr[1] = AlvrViewParams(pose: dummyPose, fov: viewFovs[1])
        
        alvr_send_tracking(targetTimestampNS, UnsafePointer(viewFovsPtr), nil, 0, nil, nil)
        
        viewFovsPtr.deallocate()
    }
    
    // The poses we get back from the ALVR runtime are in SteamVR coordniate space,
    // so we need to convert them back to local space
    func convertSteamVRViewPose(_ viewParams: [AlvrViewParams]) -> simd_float4x4 {
        let o = viewParams[0].pose.orientation
        let p = viewParams[0].pose.position
        var leftTransform = simd_float4x4(simd_quatf(ix: o.x, iy: o.y, iz: o.z, r: o.w))
        leftTransform.columns.3 = simd_float4(p.0, p.1, p.2, 1.0)
        
        leftTransform = EventHandler.shared.viewTransforms[0].inverse * leftTransform
        leftTransform = worldTrackingSteamVRTransform * leftTransform
        
        return leftTransform
    }
    
    func convertApplePositionToSteamVR(_ p: simd_float3) -> simd_float3 {
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(p.x, p.y, p.z, 1.0)
        t = self.worldTrackingSteamVRTransform.inverse * t
        return simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }
}
