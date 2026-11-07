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
    dependencies: [
        // Шифрование локальной базы: официальный пакет SQLCipher (Zetetic), только для Apple-платформ.
        // Версия закреплена точно; xcframework проверяется по контрольной сумме из пакета.
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.18.0"),
    ],
    targets: [
        // Облако: вход (Supabase Auth), синхронизация. Только Foundation, без интерфейса и без
        // сторонних SDK: тот же протокол может реализовать клиент для Windows.
        .target(name: "LeadCloud"),
        // Системный SQLCipher (libsqlcipher-dev) для сборки ядра на Linux (тестовый стенд облака).
        // На macOS не используется.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        // Ядро без интерфейса: модели, локальная база (зашифрована SQLCipher), учётные записи,
        // экспорт, журнал синхронизации. Системный libsqlite3 на macOS не подключается: два SQLite
        // в одном процессе — источник трудноуловимых ошибок, а база осталась бы без шифрования.
        .target(name: "LeadGenCore",
                dependencies: ["LeadCloud",
                               .product(name: "SQLCipher", package: "SQLCipher.swift", condition: .when(platforms: [.macOS])),
                               .target(name: "CSQLite", condition: .when(platforms: [.linux]))]),
        // Поиск лидов: источники, оценка, дедупликация. Без интерфейса, чтобы позже
        // запускать тот же код на сервере.
        .target(name: "LeadSearch", dependencies: ["LeadGenCore"]),
        // Приложение SwiftUI.
        .executableTarget(name: "LeadGenerator", dependencies: ["LeadGenCore", "LeadSearch", "LeadCloud"]),
        .testTarget(name: "LeadGenCoreTests", dependencies: ["LeadGenCore", "LeadSearch"]),
        // Интерфейс: состояние окон и меню, настройки внешнего вида, отрисовка экранов без сбоев.
        .testTarget(name: "LeadGeneratorTests", dependencies: ["LeadGenerator", "LeadGenCore", "LeadSearch", "LeadCloud"]),
        .testTarget(name: "LeadCloudTests", dependencies: ["LeadCloud", "LeadGenCore"]),
        // Шифрование локальной базы и перевод старых баз. Идёт и на macOS, и на Linux.
        .testTarget(name: "LeadStoreEncryptionTests", dependencies: ["LeadGenCore"]),
    ]
)
