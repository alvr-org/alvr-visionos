/*
Abstract:
The Entry content for a volume.
*/

import SwiftUI

/// The cube content for a volume.
struct Entry: View {
    @Environment(ViewModel.self) private var model
    @ObservedObject var eventHandler = EventHandler.shared

    var body: some View {
        VStack {
            Text("ALVR")
                .font(.system(size: 50, weight: .bold))
            
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
        .frame(minWidth: 350, minHeight: 200)
        .glassBackgroundEffect()
        
        EntryControls()
    }
}

#Preview {
    Entry()
        .environment(ViewModel())
}
