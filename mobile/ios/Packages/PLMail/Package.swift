// swift-tools-version: 6.2

import PackageDescription

// Three targets rather than three packages: the compiler enforces the same
// module boundaries either way, and one manifest is one thing to keep honest.
//
// JMAPKit deliberately depends on nothing but Foundation. It is the highest
// test-value code here — every wire shape the server can hand back — and
// keeping SwiftData and SwiftUI out of it means its suite runs in seconds
// without a simulator.
let package = Package(
    name: "PLMail",
    // Declaring this is what makes SwiftUI resolve a `Text("…")` in this
    // package against the package's own bundle instead of the app's. Without
    // it every string in every view would need an explicit `bundle: .module`.
    defaultLocalization: "en",
    // macOS is declared so `swift test` runs on the host: the JMAP codec and
    // the search parser are pure logic, and booting a simulator to assert on
    // JSON would make the tightest loop in the project the slowest. The app
    // itself ships iOS-only.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
        .library(name: "PLMailCore", targets: ["PLMailCore"]),
        .library(name: "PLMailUI", targets: ["PLMailUI"]),
    ],
    targets: [
        .target(name: "JMAPKit"),
        .target(
            name: "PLMailCore",
            dependencies: ["JMAPKit"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "PLMailUI",
            dependencies: ["PLMailCore"],
            resources: [.process("Resources")]
        ),

        // Not a product, and nothing but test targets depends on it, so it is
        // never linked into the app. It exists because the sync engine can
        // only be tested against something that actually pages — a canned
        // response cannot produce a duplicate at a page boundary.
        .target(name: "JMAPTestSupport", dependencies: ["JMAPKit"]),

        .testTarget(
            name: "JMAPKitTests",
            dependencies: ["JMAPKit", "JMAPTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PLMailCoreTests",
            dependencies: ["PLMailCore", "JMAPTestSupport"]
        ),
        .testTarget(name: "PLMailUITests", dependencies: ["PLMailUI"]),
    ],
    swiftLanguageModes: [.v6]
)
