// swift-tools-version: 6.0
// Topspin — from-scratch Swift 6 / Metal 4 engine.
//
// Manifest authority: swift-engine-app-structure.rev4.md §3.1 (nine targets, dependency rules)
// and IMPLEMENTATION-PLAN.md §4.4 (TopspinCLI takes a *direct* Runtime edge in addition to
// Server, Model, Quant, Core and Oracle, because Swift imports are not transitive and the
// composition root must instantiate Runtime's service and hand it to Server).
//
// Exactly one external dependency: Hummingbird, pinned to exactly 2.27.0 (rev4 §3.3). SwiftNIO
// arrives transitively. Package.resolved is committed so the resolution is reproducible.

import PackageDescription

let package = Package(
    name: "Topspin",
    platforms: [
        .macOS("27.0")
    ],
    // The executable's *product* is `topspin`, while its target stays `TopspinCLI` (rev4 §3.1 names
    // exactly nine targets, and `TopspinCLI` is one of them). Every CLI gate in the plan invokes
    // `swift run topspin ...`, and M0.5 asserts `test -x "$(swift build --show-bin-path)/topspin"`,
    // so the product name — not the target name — is what the build must produce.
    products: [
        .executable(name: "topspin", targets: ["TopspinCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.27.0")
    ],
    targets: [
        // Core depends on nothing (rev4 §3.1 rule 1).
        //
        // `default.metallib` is a build product of `make shaders` (rev4 §3.3) and is git-ignored.
        // `.copy` puts it in the bundle root, where `Metallib` finds it through `Bundle.module`.
        // The Makefile must therefore run BEFORE `swift build`: SwiftPM validates the declared
        // resource during manifest loading, so a missing metallib fails the build rather than
        // producing a library that loads to nothing.
        .target(
            name: "TopspinCore",
            resources: [.copy("Resources/default.metallib")]
        ),

        .target(
            name: "TopspinQuant",
            dependencies: ["TopspinCore"]
        ),

        .target(
            name: "TopspinModel",
            dependencies: ["TopspinCore", "TopspinQuant"]
        ),

        // Oracle stays a scalar reference: Model, Quant, Core only — never Runtime or Server
        // (rev4 §3.1 rule 5).
        .target(
            name: "TopspinOracle",
            dependencies: ["TopspinModel", "TopspinQuant", "TopspinCore"]
        ),

        // Runtime must never import Server (rev4 §3.1 rule 2).
        .target(
            name: "TopspinRuntime",
            dependencies: ["TopspinModel", "TopspinCore"]
        ),

        .target(
            name: "TopspinServer",
            dependencies: [
                "TopspinRuntime",
                "TopspinModel",
                "TopspinCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // The composition root. Runtime is listed explicitly per IMPLEMENTATION-PLAN.md §4.4.
        .executableTarget(
            name: "TopspinCLI",
            dependencies: [
                "TopspinRuntime",
                "TopspinServer",
                "TopspinModel",
                "TopspinQuant",
                "TopspinCore",
                "TopspinOracle",
            ]
        ),

        .testTarget(
            name: "TopspinOracleTests",
            dependencies: ["TopspinModel", "TopspinQuant", "TopspinCore", "TopspinRuntime", "TopspinOracle"]
        ),

        // The one target allowed to import TopspinCLI (rev4 §3.1 rule 3: M0.9's argv table).
        .testTarget(
            name: "TopspinServerTests",
            dependencies: ["TopspinServer", "TopspinRuntime", "TopspinCLI"]
        ),
    ]
)
