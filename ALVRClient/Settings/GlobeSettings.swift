/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Debug setting controls for the globe module.
*/

import SwiftUI

/// Debug setting controls for the globe module.
struct GlobeSettings: View {
    @Environment(ViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        
        VStack {
            Text("Globe module debug settings")
                .font(.title)
            Form {
                EarthSettings(configuration: $model.globeEarth)
                Section("System") {
                    Grid(alignment: .leading, verticalSpacing: 20) {
                        Button("Reset") {
                            model.globeEarth = .globeEarthDefault
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    GlobeSettings()
        .frame(width: 500)
        .environment(ViewModel())
}
