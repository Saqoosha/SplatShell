// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SplatShell",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Exact, and Package.resolved is committed: Sparkle downloads and
        // installs updates for the shipped app, so the linked version must be
        // answerable from the repo. Bump it in its own commit.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "SplatShell",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SplatShell",
            linkerSettings: [
                // where scripts/bundle.sh puts Sparkle.framework inside the .app
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ])
    ]
)
