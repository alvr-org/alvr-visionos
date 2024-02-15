/*
Abstract:
The model of the cube.
*/

import SwiftUI
import RealityKit

/// The model of the cube.
struct Cube: View {
    var cubeConfiguration: CubeEntity.Configuration = .init()
    var animateUpdates: Bool = false

    /// The Cube entity that the view creates and stores for later updates.
    @State private var cubeEntity: CubeEntity?

    var body: some View {
        RealityView { content in
            // Create an cube entity with rotation.
            let cubeEntity = await CubeEntity(
                configuration: cubeConfiguration)
            content.add(cubeEntity)

            // Store for later updates.
            self.cubeEntity = cubeEntity

        } update: { content in
            // Reconfigure everything when any configuration changes.
            cubeEntity?.update(
                configuration: cubeConfiguration,
                animateUpdates: animateUpdates)
        }
    }
}

#Preview {
    Cube(
        cubeConfiguration: CubeEntity.Configuration.cubeDefault
    )
}
