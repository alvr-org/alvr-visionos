//
//  Module.swift
//  ALVRClient
//
//  Created by Chris Metrailer on 2/10/24.
//

import Foundation

enum Module: String, Identifiable, CaseIterable, Equatable {
    case globe, client
    var id: Self { self }
    var name: String { rawValue.capitalized }

    var eyebrow: String {
        switch self {
        case .globe:
            "A Day in the Life"
        case .client:
            "ALVR"
        }
    }

    var heading: String {
        switch self {
        case .globe:
            "Planet Earth"
        case .client:
            "ALVR Heading"
        }
    }

    var abstract: String {
        switch self {
        case .globe:
            "A lot goes into making a day happen on Planet Earth! Discover how our globe turns and tilts to give us hot summer days, chilly autumn nights, and more."
        case .client:
            "More words"
        }
    }

    var overview: String {
        switch self {
        case .globe:
            "You can’t feel it, but Earth is constantly in motion. All planets spin on an invisible axis: ours makes one full turn every 24 hours, bringing days and nights to our home.\n\nWhen your part of the world faces the Sun, it’s daytime; when it rotates away, we move into night. When you see a sunrise or sunset, you’re witnessing the Earth in motion.\n\nWant to explore Earth’s rotation and axial tilt? Check out our interactive 3D globe and be hands-on with Earth’s movements."
        case .client:
            "Overview ALVR"
        }
    }

    var callToAction: String {
        switch self {
        case .globe: "View Globe"
        case .client: "View ALVR"
        }
    }

    static let funFacts = [
        "The Earth orbits the Sun on an invisible path called the ecliptic plane.",
        "All planets in the solar system orbit within 3°–7° of this plane.",
        "As the Earth orbits the Sun, its axial tilt exposes one hemisphere to more sunlight for half of the year.",
        "Earth's axial tilt is why different hemispheres experience different seasons."
    ]
}
