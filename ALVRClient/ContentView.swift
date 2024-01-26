//
//  ContentView.swift
//  ALVRClient
//
//  Created by Zhuowei Zhang on 1/26/24.
//

import SwiftUI
import RealityKit
#if false
import RealityKitContent
#endif

struct ContentView: View {

    @State private var enlarge = false
    @State private var showImmersiveSpace = false
    @State private var immersiveSpaceIsShown = false

    #if false
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    #endif

    var body: some View {
#if false
        RealityView { content in
            // Add the initial RealityKit content
            if let scene = try? await Entity(named: "Scene", in: realityKitContentBundle) {
                content.add(scene)
            }
        } update: { content in
            // Update the RealityKit content when SwiftUI state changes
            if let scene = content.entities.first {
                let uniformScale: Float = enlarge ? 1.4 : 1.0
                scene.transform.scale = [uniformScale, uniformScale, uniformScale]
            }
        }
        .onChange(of: showImmersiveSpace) { _, newValue in
            Task {
                if newValue {
                    switch await openImmersiveSpace(id: "ImmersiveSpace") {
                    case .opened:
                        immersiveSpaceIsShown = true
                    case .error, .userCancelled:
                        fallthrough
                    @unknown default:
                        immersiveSpaceIsShown = false
                        showImmersiveSpace = false
                    }
                } else if immersiveSpaceIsShown {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                }
            }
        }
        .gesture(TapGesture().targetedToAnyEntity().onEnded { _ in
            enlarge.toggle()
        })
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) {
                VStack (spacing: 12) {
                    Toggle("Enlarge RealityView Content", isOn: $enlarge)
                    Toggle("Show ImmersiveSpace", isOn: $showImmersiveSpace)
                }
            }
        }
#endif
    }
}

#if false
#Preview(windowStyle: .volumetric) {
    ContentView()
}
#endif
