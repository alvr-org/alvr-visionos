/*
Abstract:
The Entry content for a volume.
*/

import SwiftUI

/// The cube content for a volume.
struct Entry: View {
    @Environment(ViewModel.self) private var model

    var body: some View {
        ZStack(alignment: Alignment(horizontal: .controlPanelGuide, vertical: .bottom)) {
            Cube(
                cubeConfiguration: model.cubeEntity,
                animateUpdates: true
            )
            .alignmentGuide(.controlPanelGuide) { context in
                context[HorizontalAlignment.center]
            }

                EntryControls()
                    .offset(y: -70)
        }
        .onDisappear {
            model.isShowingEntry = false
        }
    }
}

extension HorizontalAlignment {
    /// A custom alignment to center the control panel under the cube.
    private struct ControlPanelAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[HorizontalAlignment.center]
        }
    }

    /// A custom alignment guide to center the control panel under the cube.
    static let controlPanelGuide = HorizontalAlignment(
        ControlPanelAlignment.self
    )
}

#Preview {
    Cube()
        .environment(ViewModel())
}
