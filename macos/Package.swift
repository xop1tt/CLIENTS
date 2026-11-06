// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LeadGenerator",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LeadGenerator", targets: ["LeadGenerator"]),
        .library(name: "LeadGenCore", targets: ["LeadGenCore"]),
    ],
    targets: [
        // Ядро без интерфейса: модели, расшифровка состояния, локальная база, синхронизация, экспорт.
        .target(name: "LeadGenCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Приложение SwiftUI.
        .executableTarget(name: "LeadGenerator", dependencies: ["LeadGenCore"]),
        .testTarget(name: "LeadGenCoreTests", dependencies: ["LeadGenCore"]),
    ]
)
