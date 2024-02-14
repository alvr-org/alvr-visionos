/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The launching point for the app's modules.
*/

import SwiftUI

/// The launching point for the app's modules.
struct TableOfContents: View {
    @Environment(ViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        
        VStack {
            
            Spacer(minLength: 120)

            VStack {
                // A hidden version of the final text keeps the layout fixed
                // while the overlaid visible version types on.
                TitleText(title: model.finalTitle)
                    .padding(.horizontal, 70)
                    .hidden()
                    .overlay(alignment: .leading) {
                        TitleText(title: model.titleText)
                            .padding(.leading, 70)
                    }
                Text("Discover a new way of looking at the world.")
                    .font(.title)
                    .opacity(model.isTitleFinished ? 1 : 0)
            }
            .alignmentGuide(.earthGuide) { context in
                context[VerticalAlignment.top]
            }
            .padding(.bottom, 40)

            HStack(alignment: .top, spacing: 30) {
                ForEach(Module.allCases) {
                    ModuleCard(module: $0)
                }
            }
            .padding(.bottom, 50)
            .opacity(model.isTitleFinished ? 1 : 0)

            Spacer()
        }
        .padding(.horizontal, 50)
        .typeText(
            text: $model.titleText,
            finalText: model.finalTitle,
            isFinished: $model.isTitleFinished,
            isAnimated: !model.isTitleFinished)
  
    }
}

/// The text that displays the app's title.
private struct TitleText: View {
    var title: String
    var body: some View {
        Text(title)
            .monospaced()
            .font(.system(size: 50, weight: .bold))
    }
}

extension VerticalAlignment {
    /// A custom alignment that pins the background image to the title.
    private struct EarthAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.top]
        }
    }

    /// A custom alignment guide that pins the background image to the title.
    fileprivate static let earthGuide = VerticalAlignment(
        EarthAlignment.self
    )
}

#Preview {
    NavigationStack {
        TableOfContents()
            .environment(ViewModel())
    }
}
