/*
Abstract:
The Entry content for a volume.
*/

import SwiftUI

/// The cube content for a volume.
struct Entry: View {
    @Environment(ViewModel.self) private var model
    @ObservedObject var eventHandler = EventHandler.shared
    @ObservedObject var globalSettings = GlobalSettings.shared
    @State private var dontKeepSteamVRCenter = false

    var body: some View {
        VStack {
            Text("ALVR")
                .font(.system(size: 50, weight: .bold))
                .padding()
            
            Text("Options:")
                .font(.system(size: 20, weight: .bold))
            VStack {
                Toggle(isOn: $dontKeepSteamVRCenter) {
                    Text("Crown Button long-press also recenters SteamVR")
                }
                .toggleStyle(.switch)
                .onChange(of: dontKeepSteamVRCenter) {
                    globalSettings.keepSteamVRCenter = !dontKeepSteamVRCenter
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
        
        EntryControls()
    }
}

#Preview {
    Entry()
        .environment(ViewModel())
}
