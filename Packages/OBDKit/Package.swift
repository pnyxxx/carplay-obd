// swift-tools-version: 5.10
// OBDKit : tout le protocole ELM327 / OBD-II, sans dépendance à iOS.
// Ce paquet compile et se teste aussi sous Linux (voir scripts/test-obdkit.sh).
import PackageDescription

let package = Package(
    name: "OBDKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OBDKit", targets: ["OBDKit"]),
    ],
    targets: [
        .target(name: "OBDKit"),
        .testTarget(name: "OBDKitTests", dependencies: ["OBDKit"]),
    ]
)
