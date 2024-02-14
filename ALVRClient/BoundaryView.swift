//
//  ImmersiveView.swift
//  SpatialComputeMixed
//
//  Created by Chris Metrailer on 1/12/24.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct BoundaryView: View {
    var body: some View {
        RealityView { content in
            // Add the initial RealityKit content
            if let scene = try? await Entity(named: "Scene", in: realityKitContentBundle) {
                content.add(scene)
            }
        }
    }
}
