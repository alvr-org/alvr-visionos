//
//  Extensions/SwiftUI.swift
//

import SwiftUI
import CompositorServices

//extension ImmersiveSpace<CompositorLayer, Never> {
//  @ViewBuilder
//  func disablePersistentSystemOverlaysForVisionOS2() -> some ImmersiveSpace {
//#if XCODE_BETA_16
//    if #available(visionOS 2.0, *) {
//      self.persistentSystemOverlays(ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .visible)
//    } else {
//      self
//    }
//#else
//    self
//#endif
//  }
//}

extension View {

  @ViewBuilder
    func newGameControllerSupportForVisionOS2() -> some View {
#if XCODE_BETA_16
        if #available(visionOS 2.0, *) {  // Replace with the actual version where .handlesGameControllerEvents is available
            self.handlesGameControllerEvents(matching: .gamepad)
        } else {
            self
        }
#else
        self
#endif
    }
}
