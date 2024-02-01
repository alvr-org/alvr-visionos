//
//  App.swift
//

import SwiftUI
#if os(visionOS)
import CompositorServices
#endif

#if os(visionOS)
struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
    
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled
        
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
    }
}
#endif

#if os(visionOS)
@main
struct MetalRendererApp: App {
    var body: some Scene {
#if false
        WindowGroup {
            ContentView()
        }.windowStyle(.volumetric)
#endif
        ImmersiveSpace {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = Renderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }
    }
}
#endif

#if !os(visionOS)
@main
struct Main {
    static func main() {
        let refreshRates:[Float] = [60]
        alvr_initialize(nil, nil, 1024, 1024, refreshRates, Int32(refreshRates.count), true)
        alvr_resume()
        print("alvr resume!")
        var alvrEvent = AlvrEvent()
        while true {
            let res = alvr_poll_event(&alvrEvent)
            if res {
                print(alvrEvent.tag)
                switch UInt32(alvrEvent.tag) {
                case ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue:
                        print("hud message updated")
                    let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                    alvr_hud_message(hudMessageBuffer.baseAddress)
                    print(String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8))
                    hudMessageBuffer.deallocate()
                case ALVR_EVENT_STREAMING_STARTED.rawValue:
                    print("streaming started: \(alvrEvent.STREAMING_STARTED)")
                case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                    print("streaming stopped")
                case ALVR_EVENT_HAPTICS.rawValue:
                    print("haptics: \(alvrEvent.HAPTICS)")
                case ALVR_EVENT_CREATE_DECODER.rawValue:
                    print("create decoder: \(alvrEvent.CREATE_DECODER)")
                case ALVR_EVENT_FRAME_READY.rawValue:
                    print("frame ready")
                default:
                    print("what")
                }
            }
            usleep(100000)
        }
    }
}
#endif
