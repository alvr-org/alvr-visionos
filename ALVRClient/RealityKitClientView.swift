//
//  RealityKitClientView.swift
//

import SwiftUI
import RealityKit
import AVFoundation
import CoreImage

struct RealityKitClientView: View {
    var texture: MaterialParameters.Texture?
    
    var body: some View {
        RealityView { content in
            RealityKitClientSystem.registerSystem()
            
            let material = PhysicallyBasedMaterial()
            let videoPlaneMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)
            let videoPlane = ModelEntity(mesh: videoPlaneMesh, materials: [material])
            videoPlane.name = "video_plane"
            videoPlane.components.set(InputTargetComponent())
            videoPlane.components.set(CollisionComponent(shapes: [ShapeResource.generateConvex(from: videoPlaneMesh)]))

            content.add(videoPlane)
        }
        update: { content in

        }
        .gesture(
            // TODO: We need gaze rays somehow.
            SpatialEventGesture()
                .onChanged { events in
                    //print("onchanged")
                    for event in events {
                        //print(event)
#if false
                        if event.kind == .indirectPinch && event.phase == .active {
                            WorldTracker.shared.leftIsPinching = true
                        }
                        
                        if let ray = event.selectionRay {
                            let pos = simd_float3(ray.origin + ray.direction)
                            WorldTracker.shared.testPosition = pos
                            WorldTracker.shared.leftSelectionRayOrigin = simd_float3(ray.origin)
                            WorldTracker.shared.leftSelectionRayDirection = simd_float3(ray.direction)
                        }
                        
                        if let p = event.inputDevicePose {
                            let pos = simd_float3(p.pose3D.position)
                            WorldTracker.shared.testPosition = pos
                            WorldTracker.shared.leftSelectionRayOrigin = simd_float3(p.pose3D.position) / simd_length(simd_float3(p.pose3D.position))
                            WorldTracker.shared.leftSelectionRayDirection = simd_float3()
                        }
#endif
                    }
                }
                .onEnded { events in
#if false
                    //print("onended")
                    for event in events {
                        // Remove emitters when no longer active.
                        if event.kind == .indirectPinch {
                            WorldTracker.shared.leftIsPinching = false
                        }
                    }
#endif
                }
        )
    }
}

#Preview(immersionStyle: .full) {
    RealityKitClientView()
}
