//
//  ALVRClientApp.swift
//
// High-level application stuff, notably includes:
// - Changelogs (incl app version checks)
// - The AWDL alert
// - GlobalSettings save/load hooks
// - Each different space:
//   - DummyImmersiveSpace: Literally just fetches FOV information/view transforms and exits
//   - RealityKitClient: The "40PPD" RealityKit renderer.
//   - MetalClient: Old reliable, the 26PPD Metal renderer.
// - Metal Layer config (ContentStageConfiguration)
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

struct AWDLAlertView: View {
    @Environment(\.dismissWindow) var dismissWindow
    @State private var showAlert = false
    let saveAction: ()->Void

    var body: some View {
        VStack {
            Text("Network Instability Detected")
            Text("(You should be seeing an alert box)")
            //Text("\nSignificant stuttering was detected within the last minute.\n\nMake sure your PC is directly connected to your router and that the headset is in the line of sight of the router.\n\nMake sure you have AirDrop and Handoff disabled in Settings > General > AirDrop/Handoff.\n\nAlternatively, ensure your router is set to Channel 149 (NA) or 44 (EU).")
        }
        .frame(minWidth: 650, maxWidth: 650, minHeight: 900, maxHeight: 900)
        .onAppear() {
            showAlert = true
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Network Instability Detected"),
                message: Text("Significant stuttering was detected within the last minute.\n\nMake sure your PC is directly connected to your router and that the headset is in the line of sight of the router.\n\nMake sure you have AirDrop and Handoff disabled in Settings > General > AirDrop/Handoff.\n\nAlternatively, ensure your router is set to Channel 149 (NA) or 44 (EU)."),
                primaryButton: .default(
                    Text("OK"),
                    action: {
                        dismissWindow(id: "AWDLAlert")
                    }
                ),
                secondaryButton: .destructive(
                    Text("Don't Show Again"),
                    action: {
                        ALVRClientApp.gStore.settings.dontShowAWDLAlertAgain = true
                        saveAction()
                        dismissWindow(id: "AWDLAlert")
                    }
                )
            )
        }
    }
}

@main
struct ALVRClientApp: App {
    @State private var model = ViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @State private var clientImmersionStyle: ImmersionStyle = .mixed
    
    static var gStore = GlobalSettingsStore()
    @State private var chromaKeyColor = Color(.sRGB, red: 0.98, green: 0.9, blue: 0.2)
    
    static let shared = ALVRClientApp()
    static var showedChangelog = false
    @State private var showChangelog = false
    
    let testChangelog = false
    let changelogText = """
    See the Help and Information tab for wiki links on setting up your PC and network for ALVR.\n\
    \n\
    ________________________________\n\
    \n\
    What's changed?\n\
    \n\
    • Updated to client runtime v20.13.0. Please be sure to update your streamer.\n\
    \n\
    ________________________________\n\
    \n\
    Bug fixes:\n\
    \n\
    • Fixed hand gestures not working correctly.\n\
    \n\
    ________________________________\n\
    \n\
    Known issues:\n\
    \n\
    • Hands may still show despite the hand visibility being set to off. This is a longstanding visionOS bug. Open and close the Control Center to fix.\n\
    • Controllers may be unstable on streamer versions older than v20.11.0. Please update your streamer to resolve this issue.\n\
    
    """
    
    func saveSettings() {
        do {
            try ALVRClientApp.gStore.save(settings: ALVRClientApp.gStore.settings)
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    func loadSettings() {
        do {
            try ALVRClientApp.gStore.load()
        } catch {
            fatalError(error.localizedDescription)
        }
        chromaKeyColor = Color(.sRGB, red: Double(ALVRClientApp.gStore.settings.chromaKeyColorR), green: Double(ALVRClientApp.gStore.settings.chromaKeyColorG), blue: Double(ALVRClientApp.gStore.settings.chromaKeyColorB))
        
        // Check if the app version has changed and show a changelog if so
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            if let buildVersionNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                let currentVersion = appVersion + " build " + buildVersionNumber
                print("Previous version:", ALVRClientApp.gStore.settings.lastUsedAppVersion)
                print("Current version:", currentVersion)
                if currentVersion != ALVRClientApp.gStore.settings.lastUsedAppVersion || (testChangelog && !ALVRClientApp.showedChangelog) {
                    ALVRClientApp.gStore.settings.lastUsedAppVersion = currentVersion
                    saveSettings()
                    
                    if !ALVRClientApp.showedChangelog {
                        showChangelog = true
                    }
                    ALVRClientApp.showedChangelog = true
                }
            }
        }
    }

    var body: some Scene {
        //Entry point, this is the default window chosen in Info.plist from UIApplicationPreferredDefaultSceneSessionRole
        WindowGroup(id: "Entry") {
            Entry(chromaKeyColor: $chromaKeyColor) {
                Task {
                    saveSettings()
                }
            }
            .task {
                if #unavailable(visionOS 2.0) {
                    clientImmersionStyle = .full
                }
                loadSettings()
                model.isShowingClient = false
                EventHandler.shared.initializeAlvr()
                await WorldTracker.shared.initializeAr()
                EventHandler.shared.start()
            }
            .environment(model)
            .environmentObject(EventHandler.shared)
            .environmentObject(ALVRClientApp.gStore)
            .fixedSize()
            .alert(isPresented: $showChangelog) {
                Alert(
                    title: Text("ALVR v" + ALVRClientApp.gStore.settings.lastUsedAppVersion),
                    message: Text(changelogText),
                    dismissButton: .default(
                        Text("Dismiss"),
                        action: {
                            
                        }
                    )
                )
            }
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
        
        // Alert if AWDL-like stuttering behavior is detected
        WindowGroup(id: "AWDLAlert") {
            AWDLAlertView() {
                Task {
                    saveSettings()
                }
            }
            .persistentSystemOverlays(.hidden)
            .environmentObject(ALVRClientApp.gStore)
        }
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        
        ImmersiveSpace(id: "DummyImmersiveSpace") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = DummyMetalRenderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)

        ImmersiveSpace(id: "RealityKitClient") {
            RealityKitClientView()
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)

        ImmersiveSpace(id: "MetalClient") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let system = MetalClientSystem(layerRenderer)
                system.startRenderLoop()
            }
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: $clientImmersionStyle, in: .mixed, .full)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)
    }
}
