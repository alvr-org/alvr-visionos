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
    @State private var chromaKeyColor = Color(.sRGB, red: 0.98, green: 0.9, blue: 0.2)

    var body: some Scene {
        //Entry point, this is the default window chosen in Info.plist from UIApplicationPreferredDefaultSceneSessionRole
        WindowGroup(id: "Entry") {
            Entry(settings: $gStore.settings, chromaKeyColor: $chromaKeyColor) {
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
                
                chromaKeyColor = Color(.sRGB, red: Double(gStore.settings.chromaKeyColorR), green: Double(gStore.settings.chromaKeyColorG), blue: Double(gStore.settings.chromaKeyColorB))
            }
            .environment(model)
            .environmentObject(EventHandler.shared)
            .fixedSize()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
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
        
        ImmersiveSpace(id: "DummyImmersiveSpace") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = DummyMetalRenderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }.immersionStyle(selection: .constant(.full), in: .full)
        
        ImmersiveSpace(id: "RealityKitClientWithHands") {
            RealityKitClientView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
        
        ImmersiveSpace(id: "RealityKitClientNoHands") {
            RealityKitClientView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.hidden)
        
        // This is dumb but I think it might genuinely be the correct solution.
        // But also, somehow it doesn't work, so I'm out of ideas here.
        ImmersiveSpace(id: "MetalClientWithHands") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let system = MetalClientSystem(layerRenderer)
                system.startRenderLoop()
            }
        }
        .immersionStyle(selection: $clientImmersionStyle, in: .full)
        .upperLimbVisibility(.visible)
        
        ImmersiveSpace(id: "MetalClientNoHands") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let system = MetalClientSystem(layerRenderer)
                system.startRenderLoop()
            }
        }
        .immersionStyle(selection: $clientImmersionStyle, in: .full)
        .upperLimbVisibility(.hidden)
    }
    
}
