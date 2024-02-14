// swift-tools-version: 5.7
/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A package that contains model assets.
*/

import PackageDescription

let package = Package(
    name: "WorldAssets",
    platforms: [
        .custom("xros", versionString: "1.0")
    ],
    products: [
        .library(
            name: "WorldAssets",
            targets: ["WorldAssets"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WorldAssets",
            dependencies: [])
    ]
)
