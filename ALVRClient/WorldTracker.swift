//
//  WorldTracker.swift
//
// Basically handles everything related to ARKit and SteamVR
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

let defaultSkeletonDisableHysteresis = 5.0

func jointIdxIsMoreMobile(_ idx: Int) -> Bool {
    if idx >= SteamVRJoints.numberOfJoints.rawValue {
        return false
    }
    let joint = SteamVRJoints.init(rawValue: idx)
    switch joint {
    case .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip:
        return true
    case .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip:
        return true
    case .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip:
        return true
    case .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip:
        return true
    case .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip:
        return true
    default:
        return false
    }
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
    var worldAnchorsToRemove: [WorldAnchor] = []
    var worldTrackingAddedOriginAnchor = false
    var worldTrackingSteamVRTransform: simd_float4x4 = matrix_identity_float4x4
    var worldOriginAnchor: WorldAnchor? = nil
    var planeLock = NSObject()
    var lastUpdatedTs: TimeInterval = 0
    var crownPressCount = 0
    var sentPoses = 0
    
    // Hand tracking
    var lastHandsUpdatedTs: TimeInterval = 0
    var lastSentHandsTs: TimeInterval = 0
    var lastLeftHandPose: AlvrPose = AlvrPose()
    var lastLeftHandVel: (Float, Float, Float) = (0,0,0)
    var lastLeftHandAngVel: (Float, Float, Float) = (0,0,0)
    var lastRightHandPose: AlvrPose = AlvrPose()
    var lastRightHandVel: (Float, Float, Float) = (0,0,0)
    var lastRightHandAngVel: (Float, Float, Float) = (0,0,0)
    
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
    static let leftHandOrientationCorrectionForSkeleton = simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(-1.0, 0.0, 0.0)) * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, -1.0))
    static let rightHandOrientationCorrectionForSkeleton = simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_float3(0.0, 0.0, -1.0)) * simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
    
    // For v20.11 and later
    static let leftHandOrientationCorrection = simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, -1.0, 0.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
    static let rightHandOrientationCorrection = simd_quatf(from: simd_float3(1.0, 0.0, 0.0), to: simd_float3(0.0, 1.0, 0.0)) * simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_float3(0.0, 0.0, 1.0))
    
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
    var floorCorrectionTransform = simd_float3()
    
    var leftSkeletonDisableHysteresis = 0.0
    var rightSkeletonDisableHysteresis = 0.0
    
    var pinchesAreFromRealityKit = false
    var eyeX: Float = 0.0
    var eyeY: Float = 0.0
    var eyeIsMipmapMethod: Bool = true
    var eyeTrackingActive: Bool = false
    
    var lastSkeletonLeft:[AlvrPose]? = nil
    var lastSkeletonRight:[AlvrPose]? = nil
    var lastHeadPose: AlvrPose? = nil
    var lastHeadTimestamp: Double = 0.0
    
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
        self.worldOriginAnchor = nil//WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
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
    
    func anchorDistanceFromAnchor(anchorA: WorldAnchor, anchorB: WorldAnchor) -> Float {
        let posA = anchorA.originFromAnchorTransform.columns.3
        let posB = anchorB.originFromAnchorTransform.columns.3
        return simd_distance(posA, posB)
    }
    
    // We have an origin anchor which we use to maintain SteamVR's positions
    // every time visionOS's centering changes.
    func processWorldTrackingUpdates() async {
        for await update in worldTracking.anchorUpdates {
            let keepSteamVRCenter = await ALVRClientApp.gStore.settings.keepSteamVRCenter
            print(update.event, update.anchor.id, update.anchor.description, update.timestamp)
            
            switch update.event {
            case .added, .updated:
                worldAnchors[update.anchor.id] = update.anchor
                if !self.worldTrackingAddedOriginAnchor && keepSteamVRCenter && (worldOriginAnchor == nil || update.anchor.id != worldOriginAnchor!.id) {
                    print("Early origin anchor?", anchorDistanceFromOrigin(anchor: update.anchor), "Current Origin,", self.worldOriginAnchor?.id)
                    
                    // If we randomly get an anchor added within 3.5m, consider that our origin
                    if anchorDistanceFromOrigin(anchor: update.anchor) < 3.5 && update.anchor.isTracked && (worldOriginAnchor == nil || anchorDistanceFromOrigin(anchor: update.anchor) <= anchorDistanceFromOrigin(anchor: worldOriginAnchor!)) {
                        print("Set new origin!")
                        
                        // This has a (positive) minor side-effect: all redundant anchors within 3.5m will get cleaned up,
                        // though which anchor gets chosen will be arbitrary.
                        // But there should only be one anyway.
                        if let anchor = self.worldOriginAnchor {
                            worldAnchorsToRemove.append(anchor)
                        }
                        
                        // HACK: try and restore updates?
                        self.worldOriginAnchor = update.anchor
                    }
                }
                else {
                    if worldOriginAnchor != nil && update.anchor.id != worldOriginAnchor!.id {
                        if anchorDistanceFromAnchor(anchorA: update.anchor, anchorB: worldOriginAnchor!) <= 3.5 && update.anchor.isTracked {
                            print("Removed anchor for being too close:", update.anchor.id)
                            worldAnchorsToRemove.append( update.anchor)
                        }
                    }
                }
                
                if worldOriginAnchor != nil && update.anchor.id == worldOriginAnchor!.id {
                    self.worldOriginAnchor = update.anchor
                    
                    // This seems to happen when headset is removed, or on app close.
                    if !update.anchor.isTracked {
                        print("Headset removed?")
                        //EventHandler.shared.handleHeadsetRemoved()
                        //resetPlayspace()
                        continue
                    }

                    print("recentering against", update.anchor.id, "... count", crownPressCount)
                    let anchorTransform = update.anchor.originFromAnchorTransform
                    if keepSteamVRCenter {
                        self.worldTrackingSteamVRTransform = anchorTransform
                    }
                    else {
                        print("not recentering due to settings.")
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
                        if crownPressCount >= 2 && keepSteamVRCenter {
                            print("Reset world origin!")
                            
                            // Purge all existing world anchors within 3.5m
                            for anchorPurge in worldAnchors {
                                if anchorDistanceFromOrigin(anchor: update.anchor) < 3.5 {
                                    worldAnchorsToRemove.append(anchorPurge.value)
                                }
                            }
                    
                            self.worldOriginAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
                            self.worldTrackingAddedOriginAnchor = true
                            self.worldTrackingSteamVRTransform = anchorTransform

                            do {
                                try await worldTracking.addAnchor(self.worldOriginAnchor!)
                            }
                            catch {
                                // don't care
                            }
                            
                            crownPressCount = 0
                        }
                        else if !keepSteamVRCenter {
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
    func handAnchorToPoseFallback(_ hand: HandAnchor, _ correctOrientationForSkeletonRoot: Bool) -> AlvrPose {
        let transform = self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform
        var orientation = simd_quaternion(transform)
        if correctOrientationForSkeletonRoot {
            if hand.chirality == .right {
                orientation = orientation * WorldTracker.rightHandOrientationCorrectionForSkeleton
            }
            else {
                orientation = orientation * WorldTracker.leftHandOrientationCorrectionForSkeleton
            }
        }
        else {
            if hand.chirality == .right {
                orientation = orientation * WorldTracker.rightHandOrientationCorrection
            }
            else {
                orientation = orientation * WorldTracker.leftHandOrientationCorrection
            }
        }
        let position = transform.columns.3
        let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
        return pose
    }
    
    // Palm pose for controllers
    func handAnchorToPose(_ hand: HandAnchor, _ correctOrientationForSkeletonRoot: Bool) -> AlvrPose {
        // Fall back to wrist pose
        guard let skeleton = hand.handSkeleton else {
            return handAnchorToPoseFallback(hand, correctOrientationForSkeletonRoot)
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
        var position = (middleMetacarpalPosition + middleProximalPosition) / 2.0
        
        // Gathered manually, ensuring that the pointer was consistent for the SteamVR dashboard
        let leftHandPositionAdj = simd_float3(0.0270715057, 0.0404448576, -0.0009587705)
        let rightHandPositionAdj = simd_float3(-0.0270715057, -0.0404448576, 0.0009587705)
        
        var orientation = simd_quaternion(wristTransform)
        if correctOrientationForSkeletonRoot {
            if hand.chirality == .right {
                orientation = orientation * WorldTracker.rightHandOrientationCorrectionForSkeleton
            }
            else {
                orientation = orientation * WorldTracker.leftHandOrientationCorrectionForSkeleton
            }
        }
        else {
            var positionAdj = simd_float3()
            if hand.chirality == .right {
                positionAdj += rightHandPositionAdj
            }
            else {
                positionAdj += leftHandPositionAdj
            }
            positionAdj = orientation.act(positionAdj)
            position += positionAdj.asFloat4()
            
            var adjPost20p11 = simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_normalize(simd_float3(0.0, 1.0, -0.458)))
            if hand.chirality == .right {
                orientation = orientation * WorldTracker.rightHandOrientationCorrectionForSkeleton
                adjPost20p11 = WorldTracker.rightHandOrientationCorrection * adjPost20p11
            }
            else {
                orientation = orientation * WorldTracker.leftHandOrientationCorrectionForSkeleton
                adjPost20p11 = WorldTracker.leftHandOrientationCorrection * adjPost20p11
            }
            
            orientation = orientation * adjPost20p11
        }
        
        position += floorCorrectionTransform.asFloat4()
        
        let pose = AlvrPose(orientation: AlvrQuat(x: orientation.vector.x, y: orientation.vector.y, z: orientation.vector.z, w: orientation.vector.w), position: (position.x, position.y, position.z))
        return pose
    }
    
    // Velocity-based exponential moving average filter, filters out the jitters
    // while keeping the hands responsive.
    func filterHandPose(_ lastPose: AlvrPose, _ pose: AlvrPose, _ strength: Float) -> AlvrPose {
        let dp = (pose.position.0 - lastPose.position.0, pose.position.1 - lastPose.position.1, pose.position.2 - lastPose.position.2)
        var dt = Float(lastHandsUpdatedTs - lastSentHandsTs)
        if dt <= 0.0 {
            dt = 0.010 // fallback 10ms
        }
        let linVel = simd_float3(dp.0 / dt, dp.1 / dt, dp.2 / dt)
        
        let movementThreshold: Float = 0.15
        var alpha: Float = simd_distance(simd_float3(), linVel) * 0.6 * strength
        
        // make alphas under movementThreshold even lower and higher even higher
        alpha = alpha / movementThreshold
        alpha *= alpha
        alpha *= movementThreshold

        if alpha > 1.0 {
            alpha = 1.0
        }
        else if alpha < 0.1 {
            alpha = 0.01
        }
        let invAlpha = 1.0 - alpha
        
        var positionFiltered = simd_float3(pose.position.0 * alpha + lastPose.position.0 * invAlpha, pose.position.1 * alpha + lastPose.position.1 * invAlpha, pose.position.2 * alpha + lastPose.position.2 * invAlpha)
        var orientationFiltered = simd_slerp(lastPose.orientation.asQuatf(), pose.orientation.asQuatf(), alpha)
        
        if !positionFiltered.x.isFinite || positionFiltered.x.isNaN || !positionFiltered.y.isFinite || positionFiltered.y.isNaN || !positionFiltered.z.isFinite || positionFiltered.z.isNaN {
            print("nans in hand EWMA?")
            positionFiltered = simd_float3(pose.position.0, pose.position.1, pose.position.2)
            orientationFiltered = pose.orientation.asQuatf()
        }
        
        return AlvrPose(orientationFiltered, positionFiltered)
    }

    func handAnchorToAlvrDeviceMotion(_ hand: HandAnchor) -> AlvrDeviceMotion {
        let device_id = hand.chirality == .left ? WorldTracker.deviceIdLeftHand : WorldTracker.deviceIdRightHand
        let lastPose: AlvrPose = hand.chirality == .left ? lastLeftHandPose : lastRightHandPose
        let pose: AlvrPose = filterHandPose(lastPose, handAnchorToPose(hand, false), 0.99)
        let dp = (pose.position.0 - lastPose.position.0, pose.position.1 - lastPose.position.1, pose.position.2 - lastPose.position.2)
        var dt = Float(lastHandsUpdatedTs - lastSentHandsTs)
        if dt <= 0.0 {
            dt = 0.010 // fallback 10ms
        }
        let lin_vel = (dp.0 / dt, dp.1 / dt, dp.2 / dt)
        let ang_vel = angularVelocityBetweenQuats(lastPose.orientation, pose.orientation, dt)
        //print(hand.chirality, dt, lin_vel, ang_vel)
        
        if !hand.isTracked {
            return AlvrDeviceMotion(device_id: device_id, pose: hand.chirality == .left ? lastLeftHandPose : lastRightHandPose, linear_velocity: hand.chirality == .left ? lastLeftHandVel : lastRightHandVel, angular_velocity: hand.chirality == .left ? lastLeftHandAngVel : lastRightHandAngVel)
        }
        
        if !hand.isTracked {
            return AlvrDeviceMotion(device_id: device_id, pose: hand.chirality == .left ? lastLeftHandPose : lastRightHandPose, linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0))
        }
        
        if hand.chirality == .left {
            lastLeftHandPose = pose
            lastLeftHandVel = lin_vel
            lastLeftHandAngVel = ang_vel
        }
        else {
            lastRightHandPose = pose
            lastRightHandVel = lin_vel
            lastRightHandAngVel = ang_vel
        }
        
        return AlvrDeviceMotion(device_id: device_id, pose: pose, linear_velocity: lin_vel, angular_velocity: ang_vel)
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
        
        //let val = sin(Float(CACurrentMediaTime() * 0.25)) + 1.0
        //let val2 = sin(Float(CACurrentMediaTime()))
        //let val3 = (((sin(Float(CACurrentMediaTime() * 0.025)) + 1.0) * 0.5) * 0.015)
        //let val4 = ((sin(Float(CACurrentMediaTime() * 0.125)) + 1.0) * 0.5) + 1.0
        //let val5 = ((sin(Float(CACurrentMediaTime() * 0.125)) + 1.0) * 0.5)
        
        var pinchOffset = isLeft ? (leftPinchCurrentPosition - leftPinchStartPosition) : (rightPinchCurrentPosition - rightPinchStartPosition)
        
        //print(altitude)
        
        // Gathered these by oscillating the controller along the gaze ray, and then adjusting the
        // angles slightly with pinchOffset.y until the pointer stopped moving left/right and up/down.
        // Then I adjusted the positional offset with pinchOffset.xyz.
        var adjUpDown = simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_normalize(simd_float3(0.0, 1.0, 1.7389288)))
        var adjLeftRight = simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_normalize(simd_float3((isLeft ? 1.0 : -1.0) * 0.06772318, 0.0, 1.0)))
        var adjPosition = simd_float3(isLeft ? -leftPinchEyeDelta.x : -rightPinchEyeDelta.x, isLeft ? -leftPinchEyeDelta.y : -rightPinchEyeDelta.y, isLeft ? -leftPinchEyeDelta.z : -rightPinchEyeDelta.z)
        let tipOffset: Float = -0.02522 * 2 // For some reason all the controller models have this offset? TODO: XYZ per-controller?
        
        if let otherSettings = Settings.getAlvrSettings() {
            let emulationMode = otherSettings.headset.controllers?.emulation_mode ?? ""
            if emulationMode == "RiftSTouch" {
                adjUpDown = simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_normalize(simd_float3(0.0, 1.0, 1.7349951)))
                adjLeftRight = simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_normalize(simd_float3((isLeft ? 1.0 : -1.0) * 0.00451532, 0.0, 1.0)))
            }
            else if emulationMode == "Quest2Touch" || emulationMode == "Quest3Plus" {
                adjUpDown = simd_quatf(from: simd_float3(0.0, 1.0, 0.0), to: simd_normalize(simd_float3(0.0, 1.0, 1.5898746)))
                adjLeftRight = simd_quatf(from: simd_float3(0.0, 0.0, 1.0), to: simd_normalize(simd_float3((isLeft ? 1.0 : -1.0) * 0.01, 0.0, 1.0)))
            }
            
            // TODO: ViveWand and ViveTracker
        }
        
        adjPosition.y += tipOffset
        
        let q = simd_quatf(orient) * adjLeftRight * adjUpDown
        //pinchOffset = simd_float3()
        
        pinchOffset *= 3.5
        
        let pose: AlvrPose = AlvrPose(q, convertApplePositionToSteamVR(appleOrigin + (appleDirection * -0.5) + pinchOffset + adjPosition))
        
        return AlvrDeviceMotion(device_id: device_id, pose: pose, linear_velocity: (0,0,0), angular_velocity: (0, 0, 0))
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
        let adjPose = floorCorrectionTransform.asFloat4x4()
        let rootAlvrPose = handAnchorToPose(hand, true)
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
            let transformRaw = adjPose * self.worldTrackingSteamVRTransform.inverse * hand.originFromAnchorTransform * joint.anchorFromJointTransform
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
            var isBoth = (controller.vendorName == "Joy-Con (L/R)") || !(controller.vendorName?.contains("Joy-Con") ?? true)
            //print(controller.vendorName, controller.physicalInputProfile.elements, controller.physicalInputProfile.allButtons)
            
            let b = controller.physicalInputProfile.buttons
            let a = controller.physicalInputProfile.axes
            
            var leftAssociatedButtons: [String] = []
            var rightAssociatedButtons: [String] = []
            var leftAssociatedAxis: [String] = []
            var rightAssociatedAxis: [String] = []
            
            if let gp = controller.extendedGamepad {
                isBoth = true
                
                leftAssociatedButtons = ["Left Thumbstick Button", "Button Share", "Button Options", "Left Trigger", "Left Shoulder"]
                rightAssociatedButtons = ["Button A", "Button B", "Button X", "Button Y", "Right Thumbstick Button", "Button Menu", "Button Home", "Right Trigger", "Right Shoulder"]
                leftAssociatedAxis = ["Left Thumbstick X Axis", "Left Thumbstick Y Axis", "Direction Pad X Axis", "Direction Pad Y Axis", "Left Trigger"]
                rightAssociatedAxis = ["Right Thumbstick X Axis", "Right Thumbstick Y Axis", "Right Trigger"]
                
                alvr_send_button(WorldTracker.rightButtonA, boolVal(gp.buttonA.isPressed))
                alvr_send_button(WorldTracker.rightButtonB, boolVal(gp.buttonB.isPressed))
                alvr_send_button(WorldTracker.rightButtonY, boolVal(gp.buttonY.isPressed))
                
                // Kinda weird here, we're emulating Quest controllers bc we don't have a real input profile.
                alvr_send_button(WorldTracker.leftButtonY, boolVal(gp.dpad.right.isPressed))
                alvr_send_button(WorldTracker.leftButtonX, boolVal(gp.dpad.down.isPressed || gp.dpad.left.isPressed))
                
                // ZL/ZR -> Trigger
                if self.leftPinchTrigger <= 0.0 {
                    alvr_send_button(WorldTracker.leftTriggerClick, boolVal(gp.leftTrigger.isPressed))
                    alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(gp.leftTrigger.value))
                }
                if self.rightPinchTrigger <= 0.0 {
                    alvr_send_button(WorldTracker.rightTriggerClick, boolVal(gp.rightTrigger.isPressed))
                    alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(gp.rightTrigger.value))
                }
                
                // L/R -> Squeeze
                alvr_send_button(WorldTracker.leftSqueezeClick, boolVal(gp.leftShoulder.isPressed || gp.dpad.up.isPressed))
                alvr_send_button(WorldTracker.leftSqueezeValue, scalarVal(max(gp.leftShoulder.value, gp.dpad.up.isPressed ? 1.0 : 0.0)))
                alvr_send_button(WorldTracker.leftSqueezeForce, scalarVal(max(gp.leftShoulder.value, gp.dpad.up.isPressed ? 1.0 : 0.0)))
                
                alvr_send_button(WorldTracker.rightSqueezeClick, boolVal(gp.rightShoulder.isPressed || gp.buttonX.isPressed))
                alvr_send_button(WorldTracker.rightSqueezeValue, scalarVal(max(gp.rightShoulder.value, gp.buttonX.isPressed ? 1.0 : 0.0)))
                alvr_send_button(WorldTracker.rightSqueezeForce, scalarVal(max(gp.rightShoulder.value, gp.buttonX.isPressed ? 1.0 : 0.0)))
                
                // Thumbsticks
                alvr_send_button(WorldTracker.leftThumbstickX, scalarVal(gp.leftThumbstick.xAxis.value))
                alvr_send_button(WorldTracker.leftThumbstickY, scalarVal(gp.leftThumbstick.yAxis.value))
                alvr_send_button(WorldTracker.rightThumbstickX, scalarVal(gp.rightThumbstick.xAxis.value))
                alvr_send_button(WorldTracker.rightThumbstickY, scalarVal(gp.rightThumbstick.yAxis.value))
                alvr_send_button(WorldTracker.leftThumbstickClick, boolVal(gp.leftThumbstickButton?.isPressed ?? false))
                alvr_send_button(WorldTracker.rightThumbstickClick, boolVal(gp.rightThumbstickButton?.isPressed ?? false))
                
                // System buttons of various varieties (whichever one actually hits)
                let leftSystem = (b["Button Share"]?.isPressed ?? false) || (b["Button Options"]?.isPressed ?? false)
                let rightSystem = (b["Button Home"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)
                alvr_send_button(WorldTracker.leftSystemClick, boolVal(leftSystem))
                alvr_send_button(WorldTracker.rightSystemClick, boolVal(rightSystem))
                alvr_send_button(WorldTracker.leftMenuClick, boolVal(leftSystem))
                alvr_send_button(WorldTracker.rightMenuClick, boolVal(rightSystem))
            }
            else {
                // At some point we might want to use this (for separate motion), but at the moment we cannot, because it is incomplete
                
                let b = controller.physicalInputProfile.buttons
                let a = controller.physicalInputProfile.axes
                //print(controller.vendorName, controller.physicalInputProfile.allButtons)
                if isBoth {
                    alvr_send_button(WorldTracker.rightButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonY, boolVal(b["Button Y"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightSystemClick, boolVal(b["Button Menu"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightThumbstickClick, boolVal(b["Right Thumbstick Button"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightThumbstickX, scalarVal(a["Right Thumbstick X Axis"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.rightThumbstickY, scalarVal(a["Right Thumbstick Y Axis"]?.value ?? 0.0))
                    
                    alvr_send_button(WorldTracker.rightTriggerClick, boolVal(b["Right Trigger"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(b["Right Trigger"]?.value ?? 0.0))
                    
                    alvr_send_button(WorldTracker.rightSqueezeClick, boolVal(b["Right Shoulder"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightSqueezeValue, scalarVal(b["Right Shoulder"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.rightSqueezeForce, scalarVal(b["Right Shoulder"]?.value ?? 0.0))
                    
                    
                    /*alvr_send_button(WorldTracker.leftButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonY, boolVal(b["Button Y"]?.isPressed ?? false))*/
                    alvr_send_button(WorldTracker.leftSystemClick, boolVal(b["Button Options"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftThumbstickClick, boolVal(b["Left Thumbstick Button"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftThumbstickX, scalarVal(a["Left Thumbstick X Axis"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.leftThumbstickY, scalarVal(a["Left Thumbstick Y Axis"]?.value ?? 0.0))
                    
                    alvr_send_button(WorldTracker.leftTriggerClick, boolVal(b["Left Trigger"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(b["Left Trigger"]?.value ?? 0.0))
                    
                    alvr_send_button(WorldTracker.leftSqueezeClick, boolVal(b["Left Shoulder"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftSqueezeValue, scalarVal(b["Left Shoulder"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.leftSqueezeForce, scalarVal(b["Left Shoulder"]?.value ?? 0.0))
                }
                else if !isLeft {

                //print(controller.vendorName, controller.physicalInputProfile.allButtons)
                if isBoth {
                    leftAssociatedButtons = ["Left Thumbstick Button", "Button Share", "Button Options", "Left Trigger", "Left Shoulder"]
                    rightAssociatedButtons = ["Button A", "Button B", "Button X", "Button Y", "Right Thumbstick Button", "Button Menu", "Button Home", "Right Trigger", "Right Shoulder"]
                    leftAssociatedAxis = ["Left Thumbstick X Axis", "Left Thumbstick Y Axis", "Left Trigger", "Direction Pad X Axis", "Direction Pad Y Axis"]
                    rightAssociatedAxis = ["Right Thumbstick X Axis", "Right Thumbstick Y Axis", "Right Trigger"]
                    
                    alvr_send_button(WorldTracker.rightButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonY, boolVal(b["Button Y"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightSystemClick, boolVal((b["Button Options"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)))
                    alvr_send_button(WorldTracker.rightThumbstickClick, boolVal(b["Right Thumbstick Button"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightThumbstickX, scalarVal(a["Right Thumbstick X Axis"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.rightThumbstickY, scalarVal(a["Right Thumbstick Y Axis"]?.value ?? 0.0))
                    
                    alvr_send_button(WorldTracker.rightTriggerClick, boolVal(b["Right Trigger"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(b["Right Trigger"]?.value ?? 0.0))
                    if rightPinchTrigger <= 0.0 {
                        alvr_send_button(WorldTracker.rightSystemClick, boolVal((b["Button Menu"]?.isPressed ?? false) || b["Button Home"]?.isPressed ?? false))
                        alvr_send_button(WorldTracker.rightMenuClick, boolVal((b["Button Menu"]?.isPressed ?? false) || b["Button Home"]?.isPressed ?? false))
                        alvr_send_button(WorldTracker.rightTriggerClick, boolVal(b["Right Trigger"]?.isPressed ?? false))
                        alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(b["Right Trigger"]?.value ?? 0.0))
                    }
                    
                    alvr_send_button(WorldTracker.rightSqueezeClick, boolVal(b["Right Shoulder"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightSqueezeValue, scalarVal(b["Right Shoulder"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.rightSqueezeForce, scalarVal(b["Right Shoulder"]?.value ?? 0.0))
                    
                    
                    alvr_send_button(WorldTracker.leftButtonA, boolVal(b["Direction Pad Left"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonB, boolVal(b["Direction Pad Down"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonX, boolVal(b["Direction Pad Up"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonY, boolVal(b["Direction Pad Right"]?.isPressed ?? false))
                    
                    alvr_send_button(WorldTracker.leftThumbstickClick, boolVal(b["Left Thumbstick Button"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftThumbstickX, scalarVal(a["Left Thumbstick X Axis"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.leftThumbstickY, scalarVal(a["Left Thumbstick Y Axis"]?.value ?? 0.0))
                    
                    if leftPinchTrigger <= 0.0 {
                        alvr_send_button(WorldTracker.leftSystemClick, boolVal((b["Button Share"]?.isPressed ?? false) || (b["Button Options"]?.isPressed ?? false)))
                        alvr_send_button(WorldTracker.leftMenuClick, boolVal((b["Button Share"]?.isPressed ?? false) || (b["Button Options"]?.isPressed ?? false)))
                        alvr_send_button(WorldTracker.leftTriggerClick, boolVal(b["Left Trigger"]?.isPressed ?? false))
                        alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(b["Left Trigger"]?.value ?? 0.0))
                    }
                    
                    alvr_send_button(WorldTracker.leftSqueezeClick, boolVal(b["Left Shoulder"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftSqueezeValue, scalarVal(b["Left Shoulder"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.leftSqueezeForce, scalarVal(b["Left Shoulder"]?.value ?? 0.0))
                }
                else if !isLeft {
                    rightAssociatedButtons = ["Button A", "Button B", "Button X", "Button Y", "Right Thumbstick Button", "Button Options", "Button Home", "Button Menu", "Button Home", "Right Trigger", "Right Shoulder"]
                    rightAssociatedAxis = ["Right Thumbstick X Axis", "Right Thumbstick Y Axis", "Right Trigger"]
                    
                    alvr_send_button(WorldTracker.rightButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightButtonY, boolVal(b["Button Y"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightThumbstickClick, boolVal(b["Right Thumbstick Button"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightThumbstickX, scalarVal(a["Right Thumbstick X Axis"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.rightThumbstickY, scalarVal(a["Right Thumbstick Y Axis"]?.value ?? 0.0))
                    
                    if rightPinchTrigger <= 0.0 {
                        alvr_send_button(WorldTracker.rightSystemClick, boolVal((b["Button Options"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false) || (b["Button Home"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)))
                        alvr_send_button(WorldTracker.rightMenuClick, boolVal((b["Button Options"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false) || (b["Button Home"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)))
                        alvr_send_button(WorldTracker.rightTriggerClick, boolVal(b["Right Trigger"]?.isPressed ?? false))
                        alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(b["Right Trigger"]?.value ?? 0.0))
                    }
                    
                    alvr_send_button(WorldTracker.rightSqueezeClick, boolVal(b["Right Shoulder"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.rightSqueezeValue, scalarVal(b["Right Shoulder"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.rightSqueezeForce, scalarVal(b["Right Shoulder"]?.value ?? 0.0))
                }
                else {
                    leftAssociatedButtons = ["Button A", "Button B", "Button X", "Button Y", "Left Thumbstick Button", "Button Options", "Button Home", "Button Menu", "Button Home", "Left Trigger", "Left Shoulder"]
                    leftAssociatedAxis = ["Left Thumbstick X Axis", "Left Thumbstick Y Axis", "Left Trigger"]
                    
                    alvr_send_button(WorldTracker.leftButtonA, boolVal(b["Button A"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonB, boolVal(b["Button B"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonX, boolVal(b["Button X"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftButtonY, boolVal(b["Button Y"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftSystemClick, boolVal((b["Button Options"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)))
                    alvr_send_button(WorldTracker.leftThumbstickClick, boolVal(b["Left Thumbstick Button"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftThumbstickX, scalarVal(a["Left Thumbstick X Axis"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.leftThumbstickY, scalarVal(a["Left Thumbstick Y Axis"]?.value ?? 0.0))
                    
                    alvr_send_button(WorldTracker.leftTriggerClick, boolVal(b["Left Trigger"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(b["Left Trigger"]?.value ?? 0.0))
                    if leftPinchTrigger <= 0.0 {
                        alvr_send_button(WorldTracker.leftSystemClick, boolVal((b["Button Options"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false) || (b["Button Home"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)))
                        alvr_send_button(WorldTracker.leftMenuClick, boolVal((b["Button Options"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false) || (b["Button Home"]?.isPressed ?? false) || (b["Button Menu"]?.isPressed ?? false)))
                        alvr_send_button(WorldTracker.leftTriggerClick, boolVal(b["Left Trigger"]?.isPressed ?? false))
                        alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(b["Left Trigger"]?.value ?? 0.0))
                    }
                    
                    alvr_send_button(WorldTracker.leftSqueezeClick, boolVal(b["Left Shoulder"]?.isPressed ?? false))
                    alvr_send_button(WorldTracker.leftSqueezeValue, scalarVal(b["Left Shoulder"]?.value ?? 0.0))
                    alvr_send_button(WorldTracker.leftSqueezeForce, scalarVal(b["Left Shoulder"]?.value ?? 0.0))
                }
            }
            
            for val in leftAssociatedButtons {
                if b[val]?.isPressed ?? false {
                    leftSkeletonDisableHysteresis = defaultSkeletonDisableHysteresis
                }
            }
            for val in rightAssociatedButtons {
                if b[val]?.isPressed ?? false {
                    rightSkeletonDisableHysteresis = defaultSkeletonDisableHysteresis
                }
            }
            for val in leftAssociatedAxis {
                if abs(a[val]?.value ?? 0.0) > 0.1 {
                    leftSkeletonDisableHysteresis = defaultSkeletonDisableHysteresis
                }
            }
            for val in rightAssociatedAxis {
                if abs(a[val]?.value ?? 0.0) > 0.1 {
                    rightSkeletonDisableHysteresis = defaultSkeletonDisableHysteresis
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
                                try leftEngine?.start()
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
                            
                            leftEngine?.stop()
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
                                try rightEngine?.start()
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
                            
                            rightEngine?.stop()
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
    func sendTracking(viewTransforms: [simd_float4x4], viewFovs: [AlvrFov], targetTimestamp: Double, reportedTargetTimestamp: Double, anchorTimestamp: Double, delay: Double) -> simd_float4x4 {
        var targetTimestampWalkedBack = targetTimestamp
        var deviceAnchor:DeviceAnchor? = nil
        
        // HACK: In order to get the instantaneous velocity (e.g. with current accelerometer data factored in)
        // we have to query the last head timestamp again (the anchor will be different than the last time we asked)
        // HACK: Device anchors have had hidden state in the past, fetch this first
        var deviceAnchorLastRefetched = worldTracking.queryDeviceAnchor(atTimestamp: lastHeadTimestamp)
        
        var skeletonsEnabled = false
        var steamVRInput2p0Enabled = false
        if let otherSettings = Settings.getAlvrSettings() {
            if otherSettings.headset.controllers?.hand_skeleton != nil {
                skeletonsEnabled = true
            }
            if otherSettings.headset.controllers?.hand_skeleton?.steamvr_input_2_0 ?? false {
                steamVRInput2p0Enabled = true
            }
        }
        
        Task {
            for anchor in worldAnchorsToRemove {
                do {
                    try await worldTracking.removeAnchor(anchor)
                }
                catch {
                    // don't care
                }
                worldAnchors.removeValue(forKey: anchor.id)
            }
            worldAnchorsToRemove.removeAll()
        }
        
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
            deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: targetTimestampWalkedBack)
        }
        
        if deviceAnchorLastRefetched == nil {
            deviceAnchorLastRefetched = deviceAnchor // Fallback
        }

        // Well, I'm out of ideas.
        guard let deviceAnchor = deviceAnchor else {
            print("Failed to get device anchor for future prediction!!")
            // Prevent audio crackling issues
            if sentPoses > 30 {
                // Yayyy they fixed it, but this also caused audio to cut out for random device anchor failures...
                if #unavailable(visionOS 2.0) {
                    EventHandler.shared.handleHeadsetRemoved()
                }
            }
            return matrix_identity_float4x4
        }
        
        // This is kinda fiddly: worldTracking doesn't have a way to get a list of existing anchors,
        // and addAnchor only works while fully immersed mode is fully running.
        // So we have to sandwich it in here where we know worldTracking is online.
        //
        // That aside, if we add an anchor at (0,0,0), we will get reports in processWorldTrackingUpdates()
        // every time the user recenters.
        if (!self.worldTrackingAddedOriginAnchor && sentPoses > 300) || !ALVRClientApp.gStore.settings.keepSteamVRCenter {
            if self.worldOriginAnchor == nil && ALVRClientApp.gStore.settings.keepSteamVRCenter {
                self.worldOriginAnchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
                self.worldTrackingSteamVRTransform = matrix_identity_float4x4
                
                Task {
                    do {
                        try await worldTracking.addAnchor(self.worldOriginAnchor!)
                    }
                    catch {
                        // don't care
                    }
                }
            }
            
            self.worldTrackingAddedOriginAnchor = true
            print("anchor finalized")
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
#if XCODE_BETA_16
                if #available(visionOS 2.0, *) {
                    leftPinchEyeDelta += averageViewTransformPositionalComponent
                }
#endif
            }
            //print("left pinch eye delta", leftPinchEyeDelta)
        }
        if rightIsPinching && rightSelectionRayOrigin != simd_float3() && rightPinchStartPosition == rightPinchCurrentPosition {
            rightPinchEyeDelta = headPositionApple - rightSelectionRayOrigin
            rightPinchEyeDelta -= averageViewTransformPositionalComponent
            if !pinchesAreFromRealityKit {
                rightPinchEyeDelta -= averageViewTransformPositionalComponent
#if XCODE_BETA_16
                if #available(visionOS 2.0, *) {
                    rightPinchEyeDelta += averageViewTransformPositionalComponent
                }
#endif
            }
            //print("right pinch eye delta", rightPinchEyeDelta)
        }

        floorCorrectionTransform = simd_float3() // TODO: Set floor height to plane provider floor height? Raycast it dynamically? idk.
#if XCODE_BETA_16
        if #available(visionOS 2.0, *) {
            // TODO: This might be the height of my carpet lol
            //floorCorrectionTransform.y = averageViewTransformPositionalComponent.y * 0.5
        }
#endif

        var appleOriginFromAnchor = deviceAnchor.originFromAnchorTransform
        appleOriginFromAnchor.columns.3 += floorCorrectionTransform.asFloat4()
        
        var appleOriginFromAnchorLastRefetched = deviceAnchorLastRefetched?.originFromAnchorTransform ?? deviceAnchor.originFromAnchorTransform
        appleOriginFromAnchorLastRefetched.columns.3 += floorCorrectionTransform.asFloat4()
        
        // Pinch rising-edge blocks for debugging
        if leftIsPinching && !lastLeftIsPinching && leftSelectionRayOrigin != simd_float3() && leftPinchStartPosition == leftPinchCurrentPosition {
            leftPinchEyeDelta = simd_float3()

            //print("left pinch eye delta", leftPinchEyeDelta)
        }
        if rightIsPinching && !lastRightIsPinching && rightSelectionRayOrigin != simd_float3() && rightPinchStartPosition == rightPinchCurrentPosition {
            rightPinchEyeDelta = simd_float3()
            
            // Verifying gazes: This value should be near-zero when the right eye is closed.
            // Verifies successfully on visionOS 2.0!
            /*let verifyAppleOriginFromAnchor = deviceAnchor.originFromAnchorTransform
            let verifyAppleHeadPosition = verifyAppleOriginFromAnchor.columns.3.asFloat3()
            let verifyLeftTransform = verifyAppleOriginFromAnchor * viewTransforms[0]
            
            let rayOrigin = rightSelectionRayOrigin
            //let rayOrigin = leftTransform.columns.3.asFloat3()
            
            var test = ((rayOrigin - verifyAppleHeadPosition).asFloat4() * verifyAppleOriginFromAnchor).asFloat3()
            test -= viewTransforms[0].columns.3.asFloat3()
            let test2 = rightSelectionRayOrigin - verifyLeftTransform.columns.3.asFloat3()
            print("verifying vs left eye transform, difference:")
            print("Test A:", test)
            print("Test B:", test2)*/
            
            //print("right pinch eye delta", rightPinchEyeDelta)
        }
        
        // Don't move SteamVR center/bounds when the headset recenters
        let appleOriginFromAnchor = deviceAnchor.originFromAnchorTransform
        let transform = self.worldTrackingSteamVRTransform.inverse * appleOriginFromAnchor
        let transform = self.worldTrackingSteamVRTransform.inverse * appleOriginFromAnchor
        let transformLastRefetched = self.worldTrackingSteamVRTransform.inverse * appleOriginFromAnchorLastRefetched
        let leftTransform = transform * viewTransforms[0]
        let rightTransform = transform * viewTransforms[1]
        
        let leftOrientation = simd_quaternion(leftTransform)
        let leftPosition = leftTransform.columns.3
        let leftPose = AlvrPose(leftOrientation, leftPosition)
        let rightOrientation = simd_quaternion(rightTransform)
        let rightPosition = rightTransform.columns.3
        let rightPose = AlvrPose(rightOrientation, rightPosition)
        let rightOrientation = simd_quaternion(rightTransform)
        let rightPosition = rightTransform.columns.3
        
        let leftTransformHeadLocal = viewTransforms[0]
        let rightTransformHeadLocal = viewTransforms[1]
        
        let leftOrientationHeadLocal = simd_quaternion(leftTransformHeadLocal)
        let leftPositionHeadLocal = leftTransformHeadLocal.columns.3
        let leftPoseHeadLocal = AlvrPose(leftOrientationHeadLocal, leftPositionHeadLocal)
        let rightOrientationHeadLocal = simd_quaternion(rightTransformHeadLocal)
        let rightPositionHeadLocal = rightTransformHeadLocal.columns.3
        let rightPoseHeadLocal = AlvrPose(rightOrientationHeadLocal, rightPositionHeadLocal)
        
        var trackingMotions:[AlvrDeviceMotion] = []
        var skeletonLeft:[AlvrPose]? = nil
        var skeletonRight:[AlvrPose]? = nil
        
        var skeletonLeftPtr:UnsafeMutablePointer<AlvrPose>? = nil
        var skeletonRightPtr:UnsafeMutablePointer<AlvrPose>? = nil
        
        var eyeGazeLeftPtr:UnsafeMutablePointer<AlvrPose>? = nil
        var eyeGazeRightPtr:UnsafeMutablePointer<AlvrPose>? = nil
        
        eyeGazeLeftPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 1)
        eyeGazeRightPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 1)

        // TODO: Actually get this to be as accurate as the gaze ray, currently it is not.
        
        // To get the most accurate rotations, we have each eye look at the in-space coordinates
        // we know the HoverEffect is reporting
        let directionTarget = simd_float3(-eyeX * (DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y) * 0.5 * 50.0, eyeY * (DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w) * 0.5 * 50.0, 50.0)
        let directionL = viewTransforms[0].columns.3.asFloat3() - directionTarget
        let directionR = viewTransforms[1].columns.3.asFloat3() - directionTarget
        let orientL = simd_look(at: -directionL)
        let orientR = simd_look(at: -directionR)
        let qL = leftOrientation * simd_quaternion(orientL)
        let qR = rightOrientation * simd_quaternion(orientR)

        //print(eyeX, eyeY)
        
        // TODO: Attach SteamVR controller to eyes for input anticipation/hovers.
        // Needs the gazes to be as accurate as the pinch events.
#if false
        let directionTargetApple = appleOriginFromAnchor * directionTarget.asFloat4_1()

        leftSelectionRayOrigin = appleOriginFromAnchor.columns.3.asFloat3()
        leftSelectionRayDirection = simd_normalize(appleOriginFromAnchor.columns.3.asFloat3() - directionTargetApple.asFloat3())
        //leftPinchEyeDelta = simd_float3()
        leftPinchStartPosition = simd_float3()
        leftPinchCurrentPosition = simd_float3()
#endif
        var qL = simd_quatf()
        var qR = simd_quatf()
        
        // TODO: Attach SteamVR controller to eyes for input anticipation/hovers.
        // Needs the gazes to be as accurate as the pinch events.
        let appleLeft = appleOriginFromAnchor * viewTransforms[0]
        //let appleRight = appleOriginFromAnchor * viewTransforms[1]

        if eyeIsMipmapMethod {
            var directionTarget = simd_float3()
            if eyeX < 0.0 {
                directionTarget.x = -eyeX * 0.5 * (DummyMetalRenderer.renderTangents[0].x) * 50.0 // left
            }
            else {
                directionTarget.x = -eyeX * 0.7435 * (DummyMetalRenderer.renderTangents[0].y) * 50.0 // right
            }
            if eyeY < 0.0 {
                directionTarget.y = eyeY * 0.65209925 * (DummyMetalRenderer.renderTangents[0].z) * 50.0 // top
            }
            else {
                directionTarget.y = eyeY * 0.5784546 * (DummyMetalRenderer.renderTangents[0].w) * 50.0 // bottom
            }
            directionTarget.z = 50.0
            
            let directionL = viewTransforms[0].columns.3.asFloat3() - directionTarget
            let directionR = viewTransforms[1].columns.3.asFloat3() - directionTarget
            let orientL = simd_look(at: -directionL)
            let orientR = simd_look(at: -directionR)
            qL = leftOrientation * simd_quaternion(orientL)
            qR = rightOrientation * simd_quaternion(orientR)

            if leftIsPinching {
                //print(eyeX, eyeY, val)
            }
        
            let directionTargetApple = appleLeft * directionTarget.asFloat4_1()
#if false
            leftSelectionRayOrigin = appleLeft.columns.3.asFloat3()
            leftSelectionRayDirection = simd_normalize(leftSelectionRayOrigin - directionTargetApple.asFloat3())
            //leftPinchEyeDelta = simd_float3()
            leftPinchStartPosition = simd_float3()
            leftPinchCurrentPosition = simd_float3()
            //leftIsPinching = true
#endif
        }
        else {
            //let val = Float(sin(CACurrentMediaTime() * 0.125) + 1.0)
            let panelWidth = max(DummyMetalRenderer.renderTangents[0].x, DummyMetalRenderer.renderTangents[1].x) + max(DummyMetalRenderer.renderTangents[0].y, DummyMetalRenderer.renderTangents[1].y)
            //let panelWidth = DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[1].x
            let panelHeight = max(DummyMetalRenderer.renderTangents[0].z, DummyMetalRenderer.renderTangents[1].z) + max(DummyMetalRenderer.renderTangents[0].w, DummyMetalRenderer.renderTangents[1].w)
            var directionTarget = simd_float3()
            var eyeXMod = eyeX
            var eyeYMod = eyeY
            if eyeXMod < 0.0 {
                eyeXMod *= DummyMetalRenderer.renderTangents[0].x * 0.5 // left
            }
            else {
                eyeXMod *= DummyMetalRenderer.renderTangents[0].y * 2.0 // right
            }
            if eyeYMod > 0.0 {
                eyeYMod *= DummyMetalRenderer.renderTangents[0].w * 1.3511884 // bottom
            }
            else {
                eyeYMod *= DummyMetalRenderer.renderTangents[0].z * 2.0 // top
            }
            
            // wtf
            if eyeXMod > 0.0 {
                eyeYMod -= eyeXMod * 0.5912685
            }
            //directionTarget.x = -eyeXMod * panelWidth * 50.0 // left
            //directionTarget.y = eyeY * panelHeight * 50.0 // top
            //directionTarget.z = 50.0
            directionTarget.x = -eyeXMod * panelWidth * rk_panel_depth * 0.5 * 0.5
            directionTarget.y = eyeYMod * panelHeight * rk_panel_depth * 0.5 * 0.5
            directionTarget.z = rk_panel_depth * 0.5
            
            let directionL = viewTransforms[0].columns.3.asFloat3() - directionTarget
            let directionR = viewTransforms[1].columns.3.asFloat3() - directionTarget
            let orientL = simd_look(at: -directionL)
            let orientR = simd_look(at: -directionR)
            qL = leftOrientation * simd_quaternion(orientL)
            qR = rightOrientation * simd_quaternion(orientR)

            if leftIsPinching {
                //print(eyeXMod, eyeYMod, val)
            }
        
            let directionTargetApple = appleOriginFromAnchor * directionTarget.asFloat4_1()
#if false
            leftSelectionRayOrigin = appleOriginFromAnchor.columns.3.asFloat3()
            leftSelectionRayDirection = simd_normalize(leftSelectionRayOrigin - directionTargetApple.asFloat3())
            //leftPinchEyeDelta = simd_float3()
            leftPinchStartPosition = simd_float3()
            leftPinchCurrentPosition = simd_float3()
            //leftIsPinching = true
#endif
        }
        
        eyeGazeLeftPtr?[0] = AlvrPose(qL, leftTransform.columns.3.asFloat3())
        eyeGazeRightPtr?[0] = AlvrPose(qR, rightTransform.columns.3.asFloat3())
        
        var handPoses = handTracking.latestAnchors
#if XCODE_BETA_16
        if #available(visionOS 2.0, *) {
            handPoses = handTracking.handAnchors(at: anchorTimestamp)
        }
#endif
        if let leftHand = handPoses.leftHand {
            if !(ALVRClientApp.gStore.settings.emulatedPinchInteractions && (leftIsPinching || leftPinchTrigger > 0.0)) /*&& lastHandsUpdatedTs != lastSentHandsTs*/ {
                if leftHand.isTracked {
                    trackingMotions.append(handAnchorToAlvrDeviceMotion(leftHand))
                    skeletonLeft = handAnchorToSkeleton(leftHand)
                }
                else {
                    trackingMotions.append(handAnchorToAlvrDeviceMotion(leftHand))
        
        // Skeleton disabling for SteamVR input 2.0
        leftSkeletonDisableHysteresis -= 0.01
        if leftSkeletonDisableHysteresis <= 0.0 {
            leftSkeletonDisableHysteresis = 0.0
        }
        rightSkeletonDisableHysteresis -= 0.01
        if rightSkeletonDisableHysteresis <= 0.0 {
            rightSkeletonDisableHysteresis = 0.0
        }
        
        // Disable the hysteresis if input 2.0 isn't enabled,
        // disable skeletons with the hysteresis if skeletons are disabled
        if !skeletonsEnabled {
            leftSkeletonDisableHysteresis = defaultSkeletonDisableHysteresis
            rightSkeletonDisableHysteresis = defaultSkeletonDisableHysteresis
        }
        else if !steamVRInput2p0Enabled {
            leftSkeletonDisableHysteresis = 0.0
            rightSkeletonDisableHysteresis = 0.0
        }

        if let leftHand = handPoses.leftHand {
            if !(ALVRClientApp.gStore.settings.emulatedPinchInteractions && (leftIsPinching || leftPinchTrigger > 0.0)) /*&& lastHandsUpdatedTs != lastSentHandsTs*/ {
                let handMotion = handAnchorToAlvrDeviceMotion(leftHand)
                
                // Hand motion overrides skeletons, so only send either or
                if leftHand.isTracked && leftSkeletonDisableHysteresis <= 0.0 {
                    skeletonLeft = handAnchorToSkeleton(leftHand)
                    if !steamVRInput2p0Enabled {
                        trackingMotions.append(handMotion)
                    }
                }
                else {
                    trackingMotions.append(handMotion)
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
                let handMotion = handAnchorToAlvrDeviceMotion(rightHand)

                
                // Hand motion overrides skeletons, so only send either or
                if rightHand.isTracked && rightSkeletonDisableHysteresis <= 0.0 {
                    skeletonRight = handAnchorToSkeleton(rightHand)
                    if !steamVRInput2p0Enabled {
                        trackingMotions.append(handMotion)
                    }
                }
                else {
                    trackingMotions.append(handMotion)
                }
            }
        }
        
        if skeletonLeft != nil {
            if skeletonLeft!.count >= SteamVRJoints.numberOfJoints.rawValue {
                skeletonLeftPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 26)
                for i in 0...25 {
                    skeletonLeft![i] = filterHandPose(lastSkeletonLeft?[i] ?? skeletonLeft![i], skeletonLeft![i], jointIdxIsMoreMobile(i) ? 2.0 : 1.0)
                    skeletonLeftPtr![i] = skeletonLeft![i]
                }
                
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftForearm, pose: skeletonLeft[SteamVRJoints.forearmWrist.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftElbow, pose: skeletonLeft[SteamVRJoints.forearmArm.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
            }
        }
        if let skeletonRight = skeletonRight {
            if skeletonRight.count >= SteamVRJoints.numberOfJoints.rawValue {
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftForearm, pose: skeletonLeft![SteamVRJoints.forearmWrist.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftElbow, pose: skeletonLeft![SteamVRJoints.forearmArm.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
            }
        }
        if skeletonRight != nil {
            if skeletonRight!.count >= SteamVRJoints.numberOfJoints.rawValue {
                skeletonRightPtr = UnsafeMutablePointer<AlvrPose>.allocate(capacity: 26)
                for i in 0...25 {
                    skeletonRight![i] = filterHandPose(lastSkeletonRight?[i] ?? skeletonRight![i], skeletonRight![i], jointIdxIsMoreMobile(i) ? 2.0 : 1.0)
                    skeletonRightPtr![i] = skeletonRight![i]
                }
                
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdRightForearm, pose: skeletonRight![SteamVRJoints.forearmWrist.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
                trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdRightElbow, pose: skeletonRight![SteamVRJoints.forearmArm.rawValue], linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))
            }
        }
        lastSkeletonLeft = skeletonLeft
        lastSkeletonRight = skeletonRight
        
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
                leftPinchTrigger -= 0.1
                if leftPinchTrigger < 0.0 {
                    leftPinchTrigger = 0.0
                }
                rightPinchTrigger -= 0.1
                if rightPinchTrigger < 0.0 {
                    rightPinchTrigger = 0.0
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
                if leftPinchTrigger <= 0.0 && rightPinchTrigger <= 0.0 {
                    alvr_send_button(WorldTracker.leftMenuClick, boolVal(true))
                }
                else {
                    alvr_send_button(WorldTracker.leftMenuClick, boolVal(false))
                }
                alvr_send_button(WorldTracker.leftTriggerClick, boolVal(leftPinchTrigger > 0.7))
                alvr_send_button(WorldTracker.leftTriggerValue, scalarVal(leftPinchTrigger))
                alvr_send_button(WorldTracker.rightTriggerClick, boolVal(rightPinchTrigger > 0.7))
                alvr_send_button(WorldTracker.rightTriggerValue, scalarVal(rightPinchTrigger))
                
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
                    trackingMotions.append(pinchToAlvrDeviceMotion(.left))
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
                    trackingMotions.append(pinchToAlvrDeviceMotion(.right))
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
        }
        lastLeftIsPinching = leftIsPinching
        lastRightIsPinching = rightIsPinching
        
        // Calculate the positional/angular velocities for the head
        var headLinVel: (Float, Float, Float) = (0,0,0)
        var headAngVel: (Float, Float, Float) = (0,0,0)
        
        // TODO: What changed that made this necessary?
        // Did Apple change their headset transform to not be the average of the view transforms maybe?
        // OpenXR defines the headset pose as the average of the two view transforms, so we have to do this anyhow.
        let avgViewTransformXYZ = (EventHandler.shared.viewTransforms[0].columns.3.asFloat3() + EventHandler.shared.viewTransforms[1].columns.3.asFloat3()) * 0.5
        let headPose = AlvrPose(simd_quaternion(transform), transform.columns.3.asFloat3() + (transform.columns.0.asFloat3() * avgViewTransformXYZ.x) + (transform.columns.1.asFloat3() * avgViewTransformXYZ.y) + (transform.columns.2.asFloat3() * avgViewTransformXYZ.z))
        lastHeadPose = AlvrPose(simd_quaternion(transformLastRefetched), transformLastRefetched.columns.3.asFloat3() + (transformLastRefetched.columns.0.asFloat3() * avgViewTransformXYZ.x) + (transformLastRefetched.columns.1.asFloat3() * avgViewTransformXYZ.y) + (transformLastRefetched.columns.2.asFloat3() * avgViewTransformXYZ.z))
        if let p = lastHeadPose {
            let lastPose = p
            let pose = headPose
            let dp = (pose.position.0 - lastPose.position.0, pose.position.1 - lastPose.position.1, pose.position.2 - lastPose.position.2)
            var dt = Float(targetTimestampWalkedBack - lastHeadTimestamp)
            if dt <= 0.0 {
                dt = 0.010 // fallback 10ms
            }
            headLinVel = (dp.0 / dt, dp.1 / dt, dp.2 / dt)
            headAngVel = angularVelocityBetweenQuats(lastPose.orientation, pose.orientation, dt)
        }
        lastHeadPose = headPose
        lastHeadTimestamp = targetTimestampWalkedBack
        
        let headMotion = AlvrDeviceMotion(device_id: WorldTracker.deviceIdHead, pose: headPose, linear_velocity: headLinVel, angular_velocity: headAngVel)
        trackingMotions.append(headMotion)
        
        // selection ray tests, replaces left forearm
        /*var testPoseApple = matrix_identity_float4x4
        testPoseApple.columns.3 = simd_float4(self.testPosition.x, self.testPosition.y, self.testPosition.z, 1.0)
        testPoseApple = self.worldTrackingSteamVRTransform.inverse * testPoseApple
        let testPosApple = testPoseApple.columns.3
        let testPose = AlvrPose(orientation: AlvrQuat(x: 0.0, y: 0.0, z: 0.0, w: 1.0), position: (testPosApple.x, testPosApple.y, testPosApple.z))
        trackingMotions.append(AlvrDeviceMotion(device_id: WorldTracker.deviceIdLeftForearm, pose: testPose, linear_velocity: (0, 0, 0), angular_velocity: (0, 0, 0)))*/
        
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
        viewFovsPtr[0] = AlvrViewParams(pose: leftPoseHeadLocal, fov: viewFovs[0])
        viewFovsPtr[1] = AlvrViewParams(pose: rightPoseHeadLocal, fov: viewFovs[1])

        //print((CACurrentMediaTime() - lastSentTime) * 1000.0)
        lastSentTime = CACurrentMediaTime()
        EventHandler.shared.lastRequestedTimestamp = reportedTargetTimestampNS
        lastSentHandsTs = lastHandsUpdatedTs
        
        if delay == 0.0 {
            sendGamepadInputs()
        }

        Thread {
            //Thread.sleep(forTimeInterval: delay)
            alvr_send_tracking(reportedTargetTimestampNS, UnsafePointer(viewFovsPtr), trackingMotions, UInt64(trackingMotions.count), [UnsafePointer(skeletonLeftPtr), UnsafePointer(skeletonRightPtr)], [UnsafePointer(eyeGazeLeftPtr), UnsafePointer(eyeGazeRightPtr)])
            //alvr_send_view_params(UnsafePointer(viewFovsPtr))
            alvr_send_tracking(reportedTargetTimestampNS, trackingMotions, UInt64(trackingMotions.count), [UnsafePointer(skeletonLeftPtr), UnsafePointer(skeletonRightPtr)], [UnsafePointer(eyeGazeLeftPtr), UnsafePointer(eyeGazeRightPtr)])
            
            viewFovsPtr.deallocate()
            eyeGazeLeftPtr?.deallocate()
            eyeGazeRightPtr?.deallocate()
            skeletonLeftPtr?.deallocate()
            skeletonRightPtr?.deallocate()
        }.start()
        
        return deviceAnchor.originFromAnchorTransform
        return appleOriginFromAnchor
    }
    
    func sendViewParams(viewTransforms: [simd_float4x4], viewFovs: [AlvrFov]) {
        let leftTransformHeadLocal = viewTransforms[0]
        let rightTransformHeadLocal = viewTransforms[1]
        
        let leftOrientationHeadLocal = simd_quaternion(leftTransformHeadLocal)
        let leftPositionHeadLocal = leftTransformHeadLocal.columns.3
        let leftPoseHeadLocal = AlvrPose(leftOrientationHeadLocal, leftPositionHeadLocal)
        let rightOrientationHeadLocal = simd_quaternion(rightTransformHeadLocal)
        let rightPositionHeadLocal = rightTransformHeadLocal.columns.3
        let rightPoseHeadLocal = AlvrPose(rightOrientationHeadLocal, rightPositionHeadLocal)
        
        let viewFovsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        viewFovsPtr[0] = AlvrViewParams(pose: leftPoseHeadLocal, fov: viewFovs[0])
        viewFovsPtr[1] = AlvrViewParams(pose: rightPoseHeadLocal, fov: viewFovs[1])
        
        alvr_send_view_params(UnsafePointer(viewFovsPtr))
    }
    
    // We want video frames ASAP, so we send a fake view pose/FOVs to keep the frames coming
    // until we have access to real values
    func sendFakeTracking(viewFovs: [AlvrFov], targetTimestamp: Double) {
        // Shouldn't happen
        if viewFovs.isEmpty {
            return
        }
        
        let dummyPose = AlvrPose()
        let targetTimestampNS = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        
        let viewFovsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { viewFovsPtr.deallocate() }
        viewFovsPtr[0] = AlvrViewParams(pose: dummyPose, fov: viewFovs[0])
        viewFovsPtr[1] = AlvrViewParams(pose: dummyPose, fov: viewFovs[1])
        
        alvr_send_tracking(targetTimestampNS, UnsafePointer(viewFovsPtr), nil, 0, nil, nil)
        
        viewFovsPtr.deallocate()
        alvr_send_view_params(UnsafePointer(viewFovsPtr))
        alvr_send_tracking(targetTimestampNS, nil, 0, nil, nil)
        
        
    }
    
    func angularVelocityBetweenQuats(_ q1: AlvrQuat, _ q2: AlvrQuat, _ dt: Float) -> (Float, Float, Float) {
        let r = (2.0 / dt)
        return (
            (q1.w*q2.x - q1.x*q2.w - q1.y*q2.z + q1.z*q2.y) * r,
            (q1.w*q2.y + q1.x*q2.z - q1.y*q2.w - q1.z*q2.x) * r,
            (q1.w*q2.z - q1.x*q2.y + q1.y*q2.x - q1.z*q2.w) * r
            )
    }
    
    // The poses we get back from the ALVR runtime are in SteamVR coordinate space,
    // so we need to convert them back to local space
    func convertSteamVRViewPose(_ viewParams: [AlvrViewParams]) -> simd_float4x4 {
        // Shouldn't happen, somehow happened with the Metal renderer?
        if viewParams.isEmpty {
            return matrix_identity_float4x4
        }

        let o = viewParams[0].pose.orientation
        let p = viewParams[0].pose.position
        var leftTransform = simd_float4x4(simd_quatf(ix: o.x, iy: o.y, iz: o.z, r: o.w))
        leftTransform.columns.3 = simd_float4(p.0, p.1, p.2, 1.0)
        leftTransform.columns.3 -= floorCorrectionTransform.asFloat4()
        
        leftTransform = leftTransform * EventHandler.shared.viewTransforms[0].inverse
        leftTransform = worldTrackingSteamVRTransform * leftTransform
        
        return leftTransform
    }
    
    func convertApplePositionToSteamVR(_ p: simd_float3) -> simd_float3 {
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(p.x, p.y, p.z, 1.0)
        t = self.worldTrackingSteamVRTransform.inverse * t
        t.columns.3 += floorCorrectionTransform.asFloat4()
        return simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }
}
