/*
Abstract:
The Entry content for a volume.
*/

import SwiftUI
import UIKit

struct Entry: View {
    @ObservedObject var eventHandler = EventHandler.shared
    @Binding var settings: GlobalSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.self) var environment
    let saveAction: ()->Void
    
    @State private var chromaKeyColor = Color(.sRGB, red: 0.98, green: 0.9, blue: 0.2)

    let chromaFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    
    @State private var chromaRangeMaximum: Float = 1.0
    func applyRangeSettings() {
        if settings.chromaKeyDistRangeMax < 0.001 {
            settings.chromaKeyDistRangeMax = 0.001
        }
        if settings.chromaKeyDistRangeMax > 1.0 {
            settings.chromaKeyDistRangeMax = 1.0
        }
        if settings.chromaKeyDistRangeMin < 0.0 {
            settings.chromaKeyDistRangeMin = 0.0
        }
        if settings.chromaKeyDistRangeMin > 1.0 {
            settings.chromaKeyDistRangeMin = 1.0
        }
        
        if settings.chromaKeyDistRangeMin > settings.chromaKeyDistRangeMax {
            settings.chromaKeyDistRangeMin = settings.chromaKeyDistRangeMax - 0.001
        }
        WorldTracker.shared.settings = settings
        chromaRangeMaximum = settings.chromaKeyDistRangeMax
        saveAction()
    }

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
                
                Toggle(isOn: $settings.experimental40ppd) {
                    Text("Experimental 40PPD renderer*")
                    Text("*Experimental! May cause juddering and/or nausea!")
                    .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                
                Text("Experimental Render Scale").frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                   Slider(value: $settings.realityKitRenderScale,
                          in: 0...2.5,
                          step: 0.25) {
                       Text("Experimental Render Scale")
                   }
                   .onChange(of: settings.realityKitRenderScale) {
                       applyRangeSettings()
                   }
                   TextField("Experimental Render Scale", value: $settings.realityKitRenderScale, formatter: chromaFormatter)
                   .textFieldStyle(RoundedBorderTextFieldStyle())
                   .onChange(of: settings.realityKitRenderScale) {
                       applyRangeSettings()
                   }
                   .frame(width: 100)
               }
                
                Toggle(isOn: $settings.chromaKeyEnabled) {
                    Text("Enable Chroma Keyed Passthrough*")
                    Text("*Only works with 40PPD renderer")
                    .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .onChange(of: settings.chromaKeyEnabled) {
                    WorldTracker.shared.settings = settings
                    saveAction()
                }
                
                ColorPicker("Chroma Key Color", selection: $chromaKeyColor)
                .onAppear() {
                    chromaKeyColor = Color(.sRGB, red: Double(settings.chromaKeyColorR), green: Double(settings.chromaKeyColorG), blue: Double(settings.chromaKeyColorB))
                }
                .onChange(of: chromaKeyColor) {
                    settings.chromaKeyColorR = Float((chromaKeyColor.cgColor?.components ?? [0.0, 1.0, 0.0])[0])
                    settings.chromaKeyColorG = Float((chromaKeyColor.cgColor?.components ?? [0.0, 1.0, 0.0])[1])
                    settings.chromaKeyColorB = Float((chromaKeyColor.cgColor?.components ?? [0.0, 1.0, 0.0])[2])
                    WorldTracker.shared.settings = settings
                    saveAction()
               }
               
               Text("Chroma Blend Distance Min/Max").frame(maxWidth: .infinity, alignment: .leading)
               HStack {
                   Slider(value: $settings.chromaKeyDistRangeMin,
                          in: 0...chromaRangeMaximum,
                          step: 0.01) {
                       Text("Chroma Blend Distance Min")
                   }
                   .onChange(of: settings.chromaKeyDistRangeMin) {
                       applyRangeSettings()
                       
                   }
                   TextField("Chroma Blend Distance Min", value: $settings.chromaKeyDistRangeMin, formatter: chromaFormatter)
                   .textFieldStyle(RoundedBorderTextFieldStyle())
                   .onChange(of: settings.chromaKeyDistRangeMin) {
                       applyRangeSettings()
                   }
                   .frame(width: 100)
               }
               HStack {
                   Slider(value: $settings.chromaKeyDistRangeMax,
                          in: 0.001...1,
                          step: 0.01) {
                       Text("Chroma Blend Distance Min")
                   }
                   .onChange(of: settings.chromaKeyDistRangeMax) {
                       applyRangeSettings()
                   }
                   TextField("Chroma Blend Distance Max", value: $settings.chromaKeyDistRangeMax, formatter: chromaFormatter)
                   .textFieldStyle(RoundedBorderTextFieldStyle())
                   .onChange(of: settings.chromaKeyDistRangeMax) {
                       applyRangeSettings()
                   }
                   .frame(width: 100)
               }
               
               Toggle(isOn: $settings.dismissWindowOnEnter) {
                    Text("Dismiss this window on entry")
                }
                .toggleStyle(.switch)
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
        .frame(minWidth: 650, minHeight: 800)
        .glassBackgroundEffect()
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                saveAction()
                break
            case .inactive:
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
