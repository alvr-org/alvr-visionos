/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A toggle that activates or deactivates the ALVR client scene.
*/

import SwiftUI

/// A toggle that activates or deactivates the orbit scene.
struct ClientToggle: View {
    @Environment(ViewModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var model = model

        Toggle(Module.client.callToAction, isOn: $model.isShowingClient)
            .onChange(of: model.isShowingClient) { _, isShowing in
                Task {
                    if isShowing {
                        openWindow(id: "Boundary")
                        await openImmersiveSpace(id: Module.client.name)
                    } else {
                        dismissWindow(id: "Boundary")
                        await dismissImmersiveSpace()
                    }
                }
            }
            .toggleStyle(.button)
    }
}

#Preview {
    ClientToggle()
        .environment(ViewModel())
}
