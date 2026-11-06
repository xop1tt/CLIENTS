import AppKit
import SwiftUI

/// Папка облачного диска, которую синхронизирует приложение провайдера (Dropbox, Google Диск, MEGA…).
struct CloudFolder: Identifiable, Hashable {
    let provider: String
    let url: URL
    var id: String { url.path }
}

/// Поиск папок облачных дисков на этом Mac.
///
/// Приложение не входит в облако само: для этого у каждого сервиса нужна регистрация приложения
/// и ключи разработчика. Вместо этого резервные копии кладутся в папку, которую уже синхронизирует
/// бесплатное приложение провайдера.
enum CloudStorage {
    static func detect() -> [CloudFolder] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [CloudFolder] = []

        func add(_ provider: String, _ url: URL) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard !found.contains(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == resolved }) else { return }
            found.append(CloudFolder(provider: provider, url: url))
        }

        // Современные клиенты (File Provider) монтируют диски в ~/Library/CloudStorage.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let mounts = (try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil)) ?? []
        for mount in mounts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = mount.lastPathComponent
            let account = name.split(separator: "-", maxSplits: 1).dropFirst().first.map { " (\($0))" } ?? ""
            if name.hasPrefix("GoogleDrive") {
                // В корень Google Диска писать нельзя, только в «Мой диск».
                let children = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
                if let my = children.first(where: { ["My Drive", "Мой диск"].contains($0.lastPathComponent) }) {
                    add("Google Диск" + account, my)
                }
            } else if name.hasPrefix("Dropbox") {
                add("Dropbox" + account, mount)
            } else if name.hasPrefix("OneDrive") {
                add("OneDrive" + account, mount)
            } else if name.hasPrefix("Box") {
                add("Box", mount)
            } else if name.lowercased().hasPrefix("yandex") {
                add("Яндекс Диск", mount)
            } else if name.uppercased().hasPrefix("MEGA") {
                add("MEGA", mount)
            } else if name.hasPrefix("pCloud") {
                add("pCloud", mount)
            }
        }

        // Папки старых клиентов и тех, кто синхронизирует обычную папку в домашнем каталоге.
        add("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        add("Dropbox", home.appendingPathComponent("Dropbox"))
        add("MEGA", home.appendingPathComponent("MEGA"))
        add("MEGA", home.appendingPathComponent("MEGAsync"))
        add("Яндекс Диск", home.appendingPathComponent("Yandex.Disk.localized"))
        add("Яндекс Диск", home.appendingPathComponent("Yandex.Disk"))
        add("pCloud", home.appendingPathComponent("pCloud Drive"))
        return found
    }

    /// Провайдер, если путь лежит внутри одной из найденных папок.
    static func provider(of path: String, in folders: [CloudFolder]) -> String? {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return folders.first { folder in
            let root = folder.url.resolvingSymlinksInPath().standardizedFileURL.path
            return p == root || p.hasPrefix(root + "/")
        }?.provider
    }
}

/// «Настройки → Данные»: резервные копии в облачный диск.
struct CloudBackupSection: View {
    @Environment(\.appModel) private var model
    @State private var folders: [CloudFolder] = []

    var body: some View {
        Section("Облачное хранилище") {
            if let current = CloudStorage.provider(of: model.backupDirectory, in: folders) {
                Label("Резервные копии сохраняются в «\(current)»", systemImage: "checkmark.icloud")
                    .foregroundStyle(.green)
            }
            if folders.isEmpty {
                Text("Облачные диски на этом Mac не найдены. Установите бесплатное приложение Dropbox, Google Диск, MEGA, Яндекс Диск или OneDrive, войдите в него, и его папка появится здесь. iCloud Drive включается в Системных настройках.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(folders) { folder in
                let target = destination(in: folder)
                let used = sameFolder(model.backupDirectory, target.path)
                HStack {
                    Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.provider)
                        Text(target.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if used {
                        Text("Используется").foregroundStyle(.secondary)
                    } else {
                        Button("Сохранять копии сюда") { use(target) }
                    }
                }
            }
            HStack {
                Button("Обновить список") { folders = CloudStorage.detect() }
                Button("Другая папка…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    p.message = "Выберите папку, которую синхронизирует облачный диск"
                    if p.runModal() == .OK, let url = p.url { use(url) }
                }
                Spacer()
            }
            Text("Копия базы попадает в папку облачного диска, а его приложение выгружает её в облако. Рабочая база остаётся на Mac: базу, открытую во время синхронизации, облако может повредить. На другом Mac копию можно открыть через «Восстановить из файла…». Копия не зашифрована, в ней лежат контакты лидов.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { folders = CloudStorage.detect() }
    }

    private func destination(in folder: CloudFolder) -> URL {
        folder.url.appendingPathComponent("Lead Generator Backups", isDirectory: true)
            .appendingPathComponent(model.username, isDirectory: true)
    }

    private func sameFolder(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    private func use(_ dir: URL) {
        model.backupDirectory = dir.path
        model.backupNow()
    }
}
