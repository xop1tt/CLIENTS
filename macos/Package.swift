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
        .library(name: "LeadCloud", targets: ["LeadCloud"]),
    ],
    targets: [
        // Облако: вход (Supabase Auth), синхронизация. Только Foundation, без интерфейса и без
        // сторонних SDK: тот же протокол может реализовать клиент для Windows.
        .target(name: "LeadCloud"),
        // Системный SQLite для сборки ядра на Linux (тестовый стенд облака). На macOS не используется.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        // Ядро без интерфейса: модели, локальная база, учётные записи, экспорт, журнал синхронизации.
        .target(name: "LeadGenCore",
                dependencies: ["LeadCloud", .target(name: "CSQLite", condition: .when(platforms: [.linux]))],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // Поиск лидов: источники, оценка, дедупликация. Без интерфейса, чтобы позже
        // запускать тот же код на сервере.
        .target(name: "LeadSearch", dependencies: ["LeadGenCore"]),
        // Приложение SwiftUI.
        .executableTarget(name: "LeadGenerator", dependencies: ["LeadGenCore", "LeadSearch", "LeadCloud"]),
        .testTarget(name: "LeadGenCoreTests", dependencies: ["LeadGenCore", "LeadSearch"]),
        .testTarget(name: "LeadCloudTests", dependencies: ["LeadCloud", "LeadGenCore"]),
    ]
)
