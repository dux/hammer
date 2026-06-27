// swift-tools-version:5.9
import PackageDescription

// macOS 11 (Big Sur) is the floor for Apple Silicon, so an arm64-only
// build targeting .v11 runs on every arm64 Mac. Stick to 10.15/11 APIs
// (HSplitView/VSplitView, ObservableObject) - no NavigationSplitView (13)
// or @Observable (14).
let package = Package(
  name: "HammerGUI",
  platforms: [.macOS(.v11)],
  targets: [
    .executableTarget(name: "HammerGUI", path: "Sources/HammerGUI")
  ]
)
