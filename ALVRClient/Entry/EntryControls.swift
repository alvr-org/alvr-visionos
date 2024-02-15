/*
Abstract:
Controls that allow entry into the ALVR environment.
*/

import SwiftUI

/// Controls that allow entry into the ALVR environment.
struct EntryControls: View {
    @Environment(ViewModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 17) {
            Toggle(isOn: $model.isShowingClient) {
                Label("Connect to ALVR", systemImage: "visionpro")
            }
            
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(12)
        .glassBackgroundEffect(in: .rect(cornerRadius: 50))    

        //Enable Client
        .onChange(of: model.isShowingClient) { _, isShowing in
            Task {
                if isShowing {
                    await openImmersiveSpace(id: Module.client.name)
                    dismissWindow(id: Module.entry.name)
                } else {
                    // TODO: Re-open entry through user input to dismiss immersive space
                    // once client connection is separated from render loop
                    await dismissImmersiveSpace()
                }
            }
        }

    }
}


#Preview {
    EntryControls()
        .environment(ViewModel())
}
