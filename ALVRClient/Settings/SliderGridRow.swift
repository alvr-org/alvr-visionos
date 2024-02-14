/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A supporting view for controlling developer settings.
*/

import SwiftUI

/// A grid row that contains a slider across three columns.
struct SliderGridRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    var title: String
    @Binding var value: Value
    var range: ClosedRange<Value>
    var fractionLength: Int = 1

    var body: some View {
        GridRow {
            Text(title)
            Slider(value: $value, in: range) {
                Text(title)
            }
            Text(Double(value), format: .number.precision(.fractionLength(fractionLength)))
                .monospacedDigit()
                .bold()
                .gridColumnAlignment(.trailing)
        }
    }
}

#Preview {
    Grid {
        SliderGridRow(
            title: "Some value",
            value: .constant(0),
            range: -10 ... 10
        )
    }
    .frame(width: 400)
    .padding()
}
