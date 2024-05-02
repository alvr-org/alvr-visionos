/*
Abstract:
Controls that allow entry into the ALVR environment.
*/

import SwiftUI

/// Controls that allow entry into the ALVR environment.
struct EntryControls: View {
    @Environment(ViewModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var eventHandler = EventHandler.shared
    @Binding var settings: GlobalSettings
    
    @State private var showImmersiveSpace = false
    @State private var immersiveSpaceIsShown = false
    
    let saveAction: ()->Void

    var body: some View {
        @Bindable var model = model
        
        HStack(spacing: 17) {
            if eventHandler.connectionState == .connected {
                Toggle(isOn: $model.isShowingClient) {
                    Label("Enter", systemImage: "visionpro")
                        .labelStyle(.titleAndIcon)
                        .padding(15)
                }
            } else {
                Label("Connecting...", systemImage: "visionpro")
                    .labelStyle(.titleOnly)
                    .padding(15)
            }
            
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .glassBackgroundEffect(in: .rect(cornerRadius: 50))

        //Enable Client
        .onChange(of: model.isShowingClient) { _, isShowing in
            Task {
                if isShowing {
                    WorldTracker.shared.settings = settings

                    saveAction()
                    print("Opening Immersive Space")
                    if settings.experimental40ppd {
                        if !DummyMetalRenderer.haveRenderInfo {
                            var dummySpaceIsOpened = false
                            while !dummySpaceIsOpened {
                                switch await openImmersiveSpace(id: "DummyImmersiveSpace") {
                                case .opened:
                                    dummySpaceIsOpened = true
                                case .error, .userCancelled:
                                    fallthrough
                                @unknown default:
                                    dummySpaceIsOpened = false
                                }
                            }
                            
                            while dummySpaceIsOpened && !DummyMetalRenderer.haveRenderInfo {
                                try! await Task.sleep(nanoseconds: 1_000_000)
                            }
                            
                            await dismissImmersiveSpace()
                            try! await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        
                        if !DummyMetalRenderer.haveRenderInfo {
                            print("MISSING VIEW INFO!!")
                        }
                        
                        WorldTracker.shared.worldTrackingAddedOriginAnchor = false
                        
                        print("Open real immersive space")
                        
                        var id = "RealityKitClientWithHands"
                        if settings.showHandsOverlaid {
                            id = "RealityKitClientWithHands"
                        }
                        else {
                            id = "RealityKitClientNoHands"
                        }
                        
                        switch await openImmersiveSpace(id: id) {
                        case .opened:
                            immersiveSpaceIsShown = true
                        case .error, .userCancelled:
                            fallthrough
                        @unknown default:
                            immersiveSpaceIsShown = false
                            showImmersiveSpace = false
                        }
                    }
                    else if settings.showHandsOverlaid {
                        await openImmersiveSpace(id: "MetalClientWithHands")
                    }
                    else {
                        await openImmersiveSpace(id: "MetalClientNoHands")
                    }
                    if settings.dismissWindowOnEnter {
                        dismissWindow(id: "Entry")
                    }
                }
            }
        }

    }
}


#Preview {
    EntryControls(settings: .constant(GlobalSettings.sampleData), saveAction: {})
        .environment(ViewModel())
}
