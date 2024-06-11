//
//  RealityKitClientView.swift
//

import SwiftUI
import RealityKit
import AVFoundation
import CoreImage
import GameController

struct RealityKitClientView: View {
    var texture: MaterialParameters.Texture?
    
    static func handleSpatialEvent(_ value: EntityTargetValue<SpatialEventCollection>?, _ event: SpatialEventCollection.Event) {
        if value != nil {
            WorldTracker.shared.pinchesAreFromRealityKit = true
        }
        else {
            WorldTracker.shared.pinchesAreFromRealityKit = false
        }

        var isInProgressPinch = false
        var isRight = false
        if event.id.hashValue == WorldTracker.shared.leftSelectionRayId {
            isInProgressPinch = true
        }
        else if event.id.hashValue == WorldTracker.shared.rightSelectionRayId {
            isInProgressPinch = true
            isRight = true
        }
        
        if event.kind == .indirectPinch && event.phase == .active {
            if !isInProgressPinch {
                if WorldTracker.shared.leftSelectionRayId != -1 {
                    isRight = true
                }
                
                if isRight && WorldTracker.shared.rightSelectionRayId != -1 {
                    print("THIRD HAND??? early fallback")
                    
                    WorldTracker.shared.leftSelectionRayId = -1
                    WorldTracker.shared.rightSelectionRayId = -1
                    isRight = false
                    
                    print(event, event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId)
                    return
                }
                
                if isRight {
                    WorldTracker.shared.rightSelectionRayId = event.id.hashValue
                }
                else if WorldTracker.shared.leftSelectionRayId == -1 {
                    WorldTracker.shared.leftSelectionRayId = event.id.hashValue
                }
                else {
                    print("THIRD HAND???")
                    print(event, event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId)
                    return
                }
            }
            
            if isRight {
                WorldTracker.shared.rightIsPinching = true
            }
            else {
                WorldTracker.shared.leftIsPinching = true
            }
        }
        else if event.kind == .indirectPinch {
            if event.id.hashValue == WorldTracker.shared.leftSelectionRayId {
                WorldTracker.shared.leftIsPinching = false
                WorldTracker.shared.leftSelectionRayId = -1
            }
            else if event.id.hashValue == WorldTracker.shared.rightSelectionRayId {
                WorldTracker.shared.rightIsPinching = false
                WorldTracker.shared.rightSelectionRayId = -1
            }
            return
        }
        
        //print(event.id.hashValue, isRight, isInProgressPinch, WorldTracker.shared.leftSelectionRayId, WorldTracker.shared.rightSelectionRayId, event.inputDevicePose)
    
        // For eyes: inputDevicePose is the pinch connect location, and the selection ray is
        // the eye center plus the gaze
        // For AssistiveTouch mouse: inputDevicePose is locked to the last plane the device was on, and
        // the selection ray is some random pose?
        // For keyboard accessibility touch: inputDevicePose is some random place, selectionRay is 0,0,0
        
        // selectionRay origin + direction
        if let ray = event.selectionRay {
            let origin = value?.convert(ray.origin, from: .local, to: event.targetedEntity!.parent!) ?? simd_float3(ray.origin)
            let direction = simd_normalize((value?.convert(ray.origin + ray.direction, from: .local, to: event.targetedEntity!.parent!) ?? origin + simd_float3(ray.direction)) - origin)
            let pos = origin + direction
            
            WorldTracker.shared.testPosition = pos
            if isRight {
                WorldTracker.shared.rightSelectionRayOrigin = origin
                WorldTracker.shared.rightSelectionRayDirection = direction
            }
            else {
                WorldTracker.shared.leftSelectionRayOrigin = origin
                WorldTracker.shared.leftSelectionRayDirection = direction
            }
        }
        
        // inputDevicePose
        if let inputPose = event.inputDevicePose {
            let pos = value?.convert(inputPose.pose3D.position, from: .local, to: event.targetedEntity!.parent!) ?? simd_float3(inputPose.pose3D.position)
            let rot = value?.convert(inputPose.pose3D.rotation, from: .local, to: event.targetedEntity!.parent!) ?? simd_quatf(inputPose.pose3D.rotation)
            //WorldTracker.shared.testPosition = pos
            
            // Started a pinch and have a start position
            if !isInProgressPinch {
                if isRight {
                    WorldTracker.shared.rightPinchStartPosition = pos
                    WorldTracker.shared.rightPinchCurrentPosition = pos
                    WorldTracker.shared.rightPinchStartAngle = rot
                    WorldTracker.shared.rightPinchCurrentAngle = rot
                }
                else {
                    WorldTracker.shared.leftPinchStartPosition = pos
                    WorldTracker.shared.leftPinchCurrentPosition = pos
                    WorldTracker.shared.leftPinchStartAngle = rot
                    WorldTracker.shared.leftPinchCurrentAngle = rot
                }
                
            }
            else {
                if isRight {
                    WorldTracker.shared.rightPinchCurrentPosition = pos
                    WorldTracker.shared.rightPinchCurrentAngle = rot
                }
                else {
                    WorldTracker.shared.leftPinchCurrentPosition = pos
                    WorldTracker.shared.leftPinchCurrentAngle = rot
                }
            }
        }
        else {
            // Just in case
            if !isInProgressPinch {
                if isRight {
                    WorldTracker.shared.rightPinchStartPosition = simd_float3()
                    WorldTracker.shared.rightPinchCurrentPosition = simd_float3()
                    WorldTracker.shared.rightPinchStartAngle = simd_quatf()
                    WorldTracker.shared.rightPinchCurrentAngle = simd_quatf()
                }
                else {
                    WorldTracker.shared.leftPinchStartPosition = simd_float3()
                    WorldTracker.shared.leftPinchCurrentPosition = simd_float3()
                    WorldTracker.shared.leftPinchStartAngle = simd_quatf()
                    WorldTracker.shared.leftPinchCurrentAngle = simd_quatf()
                }
                
            }
        }
    }
    
    var body: some View {
        RealityView { content in
            let material = UnlitMaterial(color: .white)
            let videoPlaneMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)
            let videoPlane = ModelEntity(mesh: videoPlaneMesh, materials: [material])
            videoPlane.name = "video_plane"
            videoPlane.components.set(MagicRealityKitClientSystemComponent())
            videoPlane.components.set(InputTargetComponent())
            videoPlane.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMesh)]))
            videoPlane.scale = simd_float3(0.0, 0.0, 0.0)
            
            let material2 = UnlitMaterial(color: UIColor(white: 0.0, alpha: 1.0))
            //material2.blending = .transparent(opacity: 0.0)
            let cubeMesh = MeshResource.generateBox(size: 1.0)
            try? cubeMesh.addInvertedNormals()
            let backdrop = ModelEntity(mesh: cubeMesh, materials: [material2])
            backdrop.name = "backdrop_cube"
            backdrop.components.set(InputTargetComponent())
            backdrop.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMesh)]))
            backdrop.scale = simd_float3(0.0, 0.0, 0.0)

            content.add(videoPlane)
            content.add(backdrop)
            
            MagicRealityKitClientSystemComponent.registerComponent()
            RealityKitClientSystem.registerSystem()
        }
        update: { content in

        }
        .newGameControllerSupportForVisionOS2()
        .gesture(
            SpatialEventGesture(coordinateSpace: .local)
                .targetedToAnyEntity()
                .onChanged { value in
                    for v in value.gestureValue {
                        RealityKitClientView.handleSpatialEvent(value, v)
                    }
                }
                .onEnded { value in
                    for v in value.gestureValue {
                        RealityKitClientView.handleSpatialEvent(value, v)
                    }
                }
        )
    }
}
