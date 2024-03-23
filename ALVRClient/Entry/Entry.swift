/*
Abstract:
The Entry content for a volume.
*/

import SwiftUI

struct Entry: View {
    @ObservedObject var eventHandler = EventHandler.shared
    @Binding var settings: GlobalSettings
    @Environment(\.scenePhase) private var scenePhase
    let saveAction: ()->Void

    var body: some View {
        VStack {
            Text("ALVR")
                .font(.system(size: 50, weight: .bold))
                .padding()
            
            Text("Options:")
                .font(.system(size: 20, weight: .bold))
            VStack {
                Toggle(isOn: $settings.showHandsOverlaid) {
                    Text("Show hands overlaid")
                }
                .toggleStyle(.switch)
                
                Toggle(isOn: $settings.keepSteamVRCenter) {
                    Text("Crown Button long-press ignored by SteamVR")
                }
                .toggleStyle(.switch)
                
                Toggle(isOn: $settings.setDisplayTo96Hz) {
                    Text("Optimize refresh rate for 24P film*")
                    Text("*May cause skipping when displaying 30P content, or while passthrough is active")
                    .font(.system(size: 10))
                }
                .toggleStyle(.switch)

                Toggle(isOn: $settings.enableMetalFX) {
                    Text("Enable MetalFX for upscaling*")
                }
                .toggleStyle(.switch)
                
                if settings.enableMetalFX {
                    Text("MetalFX Upscaling \(String(format: "%.1f", settings.upscalingFactor))")
                        .font(.system(size: 20, weight: .bold))
                    
                    Slider(value: $settings.upscalingFactor, in: 1.1 ... 2.5, step: 0.1) {
                    }
                }
                
                
            }
            .frame(width: 450)
            .padding()
            
            Text("Connection Information:")
                .font(.system(size: 20, weight: .bold))
            
            if eventHandler.hostname != "" && eventHandler.IP != "" {
                let columns = [
                    GridItem(.fixed(100), alignment: .trailing),
                    GridItem(.fixed(150), alignment: .leading)
                ]

                LazyVGrid(columns: columns) {
                    Text("hostname:")
                    Text(eventHandler.hostname)
                    Text("IP:")
                    Text(eventHandler.IP)
                }
                .frame(width: 250, alignment: .center)
            }
        }
        .frame(minWidth: 650, minHeight: 500)
        .glassBackgroundEffect()
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                print(settings.keepSteamVRCenter)
                saveAction()
                break
            case .inactive:
                print(settings.keepSteamVRCenter)
                saveAction()
                break
            case .active:
                break
            @unknown default:
                break
            }
        }
        
        EntryControls(settings: $settings, saveAction: saveAction)
    }
}

struct Entry_Previews: PreviewProvider {
    static var previews: some View {
        Entry(settings: .constant(GlobalSettings.sampleData), saveAction: {})
    }
}
