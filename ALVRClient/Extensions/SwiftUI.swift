//
//  Extensions/SwiftUI.swift
//

import SwiftUI

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
