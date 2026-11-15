// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RizzoCharge", platforms: [.macOS(.v13)], products: [.executable(name: "RizzoCharge", targets: ["RizzoCharge"])], targets: [.executableTarget(name: "RizzoCharge", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]), .testTarget(name: "RizzoChargeTests", dependencies: ["RizzoCharge"])])
