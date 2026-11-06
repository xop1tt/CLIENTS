// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LeadGenerator",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LeadGenerator", targets: ["LeadGenerator"]),
        .library(name: "LeadGenCore", targets: ["LeadGenCore"]),
        .library(name: "LeadSearch", targets: ["LeadSearch"]),
    ],
    targets: [
        // Ядро без интерфейса: модели, локальная база, учётные записи, экспорт.
        .target(name: "LeadGenCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Поиск лидов: источники, оценка, дедупликация. Без интерфейса, чтобы позже
        // запускать тот же код на сервере.
        .target(name: "LeadSearch", dependencies: ["LeadGenCore"]),
        // Приложение SwiftUI.
        .executableTarget(name: "LeadGenerator", dependencies: ["LeadGenCore", "LeadSearch"]),
        .testTarget(name: "LeadGenCoreTests", dependencies: ["LeadGenCore", "LeadSearch"]),
    ]
)
