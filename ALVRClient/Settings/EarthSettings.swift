/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Settings for the Earth entity.
*/

import SwiftUI

/// Controls for settings specific to the Earth entity.
struct EarthSettings: View {
    @Binding var configuration: EarthEntity.Configuration

    private var solarSunAngleBinding: Binding<Double> {
        Binding<Double>(
            get: { configuration.sunAngle.degrees },
            set: { configuration.sunAngle = .degrees($0) }
        )
    }

    var body: some View {
        Section("Earth") {
            Grid(alignment: .leading, verticalSpacing: 20) {
                SliderGridRow(
                    title: "Scale",
                    value: $configuration.scale,
                    range: 0 ... 1e3)
                SliderGridRow(
                    title: "Rotation speed",
                    value: $configuration.speed,
                    range: 0 ... 1,
                    fractionLength: 3)

                Divider()

                SliderGridRow(
                    title: "X",
                    value: $configuration.position.x,
                    range: -10 ... 10)
                SliderGridRow(
                    title: "Y",
                    value: $configuration.position.y,
                    range: -10 ... 10)
                SliderGridRow(
                    title: "Z",
                    value: $configuration.position.z,
                    range: -10 ... 10)

                Divider()

                Toggle("Show Poles", isOn: $configuration.showPoles)
                SliderGridRow(
                    title: "Pole height",
                    value: $configuration.poleLength,
                    range: 0 ... 1,
                    fractionLength: 3)
                SliderGridRow(
                    title: "Pole thickness",
                    value: $configuration.poleThickness,
                    range: 0 ... 1,
                    fractionLength: 3)
            }
        }
        Section("Sun") {
            Grid(alignment: .leading, verticalSpacing: 20) {
                Toggle("Show Sun", isOn: $configuration.showSun)
                SliderGridRow(
                    title: "Sun intensity",
                    value: $configuration.sunIntensity,
                    range: 0 ... 20)
                SliderGridRow(
                    title: "Angle",
                    value: solarSunAngleBinding,
                    range: 0 ... 360)
            }
        }
    }
}
