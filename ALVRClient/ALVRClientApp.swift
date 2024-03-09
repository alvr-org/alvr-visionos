//
//  App.swift
//

import SwiftUI
import CompositorServices

struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
    
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled
        
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
        
        configuration.colorFormat = .rgba16Float
    }
}

@main
struct MetalRendererApp: App {
    @State private var model = ViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var clientImmersionStyle: ImmersionStyle = .full
    @StateObject private var gStore = GlobalSettingsStore()

    var body: some Scene {
        //Entry point, this is the default window chosen in Info.plist from UIApplicationPreferredDefaultSceneSessionRole
        WindowGroup(id: "Entry") {
            Entry(settings: $gStore.settings) {
                Task {
                    do {
                        try gStore.save(settings: gStore.settings)
                    } catch {
                        fatalError(error.localizedDescription)
                    }
                    WorldTracker.shared.settings = gStore.settings // Hack: actually sync settings. We should probably rethink this.
                }
            }
            .task {
                do {
                    try gStore.load()
                } catch {
                    fatalError(error.localizedDescription)
                }
                model.isShowingClient = false
                EventHandler.shared.initializeAlvr()
                await WorldTracker.shared.initializeAr(settings: gStore.settings)
                EventHandler.shared.start()
            }
            .environment(model)
            .environmentObject(EventHandler.shared)
        }
        .defaultSize(width: 650, height: 600)
        .windowStyle(.plain)
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                // TODO: revisit if we decide to let app run in background (ie, keep it open + reconnect when headset is donned)
                /*if !model.isShowingClient {
                    //Lobby closed manually: disconnect ALVR
                    //EventHandler.shared.stop()
                    if EventHandler.shared.alvrInitialized {
                        alvr_pause()
                    }
                }
                if !EventHandler.shared.streamingActive {
                    EventHandler.shared.handleHeadsetRemoved()
                }*/
                break
            case .inactive:
                // Scene inactive, currently no action for this
                break
            case .active:
                // Scene active, make sure everything is started if it isn't
                // TODO: revisit if we decide to let app run in background (ie, keep it open + reconnect when headset is donned)
                /*if !model.isShowingClient {
                    WorldTracker.shared.resetPlayspace()
                    EventHandler.shared.initializeAlvr()
                    EventHandler.shared.start()
                    EventHandler.shared.handleHeadsetRemovedOrReentry()
                }
                if EventHandler.shared.alvrInitialized {
                    alvr_resume()
                }*/
                EventHandler.shared.handleHeadsetEntered()
                break
            @unknown default:
                break
            }
        }
        
        ImmersiveSpace(id: "Client") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = Renderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }
        .immersionStyle(selection: $clientImmersionStyle, in: .full)
        .upperLimbVisibility(gStore.settings.showHandsOverlaid ? .visible : .hidden)
    }
    
}
