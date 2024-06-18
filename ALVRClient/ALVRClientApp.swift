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
    • Updated client protocol to v20.8.2\n\
    • Added support for 100Hz on visionOS 2\n\
    • Added AWDL heuristic to show one-time notification if the network conditions are bad\n\
    • Added support for visionOS 2 additions: Chroma keying for the default renderer, and high-Hz hand tracking\n\
    • Added support for simulating visionOS gaze-pinch interactions as Index controller trigger presses. Can technically work in tandem with device-connected controllers.\n\
    • Improved RealityKit render clarity by using bicubic filtering for quad and up/downscaling to client scale.\n\
    • Frame pacing and render performance has been improved. Experimental renderer can now render at 37PPD (2.0x) without throttling, possibly higher.\n\
    \n\
    ________________________________\n\
    \n\
    Bug fixes:\n\
    \n\
    • Fixed a bunch of memory leaks.\n\
    • Fixed a bunch of crash reports (AV1 causing a crash, a few other edge-case crashes).\n\
    • Fixed a bug in Experimental renderer where the previously-open launch window would secretly allocate large textures, steal frames, and schedule GPU work for no reason.\n\
    • Fixed visuals appearing too large or too small with chroma keyed passthrough in the Experimental Renderer.\n\
    \n\
    ________________________________\n\
    \n\
    Known issues:\n\
    \n\
    • On visionOS 2, with the default renderer and chroma keyed passthrough, eye comfort settings Near/Far may cause visuals to appear too small or too large.\n\
    \n\
    
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
        }.immersionStyle(selection: .constant(.full), in: .full)
        
        ImmersiveSpace(id: "RealityKitClient") {
            RealityKitClientView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)
        
        ImmersiveSpace(id: "MetalClient") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let system = MetalClientSystem(layerRenderer)
                system.startRenderLoop()
            }
        }
        .immersionStyle(selection: $clientImmersionStyle, in: .mixed, .full)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)
    }
    
}
