/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The globe content for a volume.
*/

import SwiftUI

/// The globe content for a volume.
struct Globe: View {
    @Environment(ViewModel.self) private var model

    @State var axRotateClockwise: Bool = false
    @State var axRotateCounterClockwise: Bool = false

    var body: some View {
        ZStack(alignment: Alignment(horizontal: .controlPanelGuide, vertical: .bottom)) {
            Earth(
                earthConfiguration: model.globeEarth,
                animateUpdates: true
            ) { event in
                if event.key.defaultValue == EarthEntity.AccessibilityActions.rotateCW.name.defaultValue {
                    axRotateClockwise.toggle()
                } else if event.key.defaultValue == EarthEntity.AccessibilityActions.rotateCCW.name.defaultValue {
                    axRotateCounterClockwise.toggle()
                }
            }
            .dragRotation(
                pitchLimit: .degrees(90),
                axRotateClockwise: axRotateClockwise,
                axRotateCounterClockwise: axRotateCounterClockwise)
            .alignmentGuide(.controlPanelGuide) { context in
                context[HorizontalAlignment.center]
            }

            GlobeControls()
                .offset(y: -70)
        }
        .onChange(of: model.isGlobeRotating) { _, isRotating in
            model.globeEarth.speed = isRotating ? 0.1 : 0
        }
        .onDisappear {
            model.isShowingGlobe = false
        }
    }
}

extension HorizontalAlignment {
    /// A custom alignment to center the control panel under the globe.
    private struct ControlPanelAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[HorizontalAlignment.center]
        }
    }

    /// A custom alignment guide to center the control panel under the globe.
    static let controlPanelGuide = HorizontalAlignment(
        ControlPanelAlignment.self
    )
}

#Preview {
    Globe()
        .environment(ViewModel())
}
