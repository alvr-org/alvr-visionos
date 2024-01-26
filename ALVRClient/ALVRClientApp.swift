//
//  App.swift
//

import SwiftUI
#if false
import CompositorServices
#endif

#if false
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

#if false
@main
#endif
struct MetalRendererApp: App {
    var body: some Scene {
#if false
        WindowGroup {
            ContentView()
        }.windowStyle(.volumetric)
#endif
        
#if true
        WindowGroup {
            ContentView()
        }
#endif
        
#if false
        ImmersiveSpace(id: "ImmersiveSpace") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = Renderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }.immersionStyle(selection: .constant(.full), in: .full)
#endif
    }
}

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
                switch alvrEvent.tag {
                case 0:
                        print("hud message updated")
                    let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                    alvr_hud_message(hudMessageBuffer.baseAddress)
                    print(String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8))
                    hudMessageBuffer.deallocate()
                default:
                    print("what")
                }
            }
            usleep(100000)
        }
    }
}
