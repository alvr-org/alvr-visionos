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
            content.add(videoPlane)
        } update: { content in
            
        }
    }
}

#Preview(immersionStyle: .full) {
    RealityKitClientView()
}
