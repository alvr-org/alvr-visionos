/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The module detail content that's specific to the globe module.
*/

import SwiftUI

/// The module detail content that's specific to the globe module.
struct GlobeModule: View {
    var body: some View {
        Image("GlobeHero")
            .resizable()
            .scaledToFit()
    }
}

#Preview {
    GlobeModule()
        .padding()
}
