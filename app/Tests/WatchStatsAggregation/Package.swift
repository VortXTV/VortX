// swift-tools-version:6.0
import PackageDescription

// Standalone test package for the PURE Watch Stats aggregation. It compiles the REAL
// `app/SourcesShared/WatchStatsAggregation.swift` (symlinked into Sources) with no app / engine
// dependencies, so the record normalization and the records -> stats aggregation can be unit-tested in
// isolation. This package is intentionally OUTSIDE the Xcode project (the app itself has no test target,
// per the repository guide); run it with `swift test` from this directory.
let package = Package(
    name: "WatchStatsAggregation",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v18)],
    targets: [
        .target(name: "WatchStatsAggregation", path: "Sources/WatchStatsAggregation"),
        .testTarget(
            name: "WatchStatsAggregationTests",
            dependencies: ["WatchStatsAggregation"],
            path: "Tests/WatchStatsAggregationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
