import LeadGenCore
import LeadSearch
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppearanceSettings.self) private var look
    @Environment(\.openSettings) private var openSettings
    @Environment(SessionModel.self) private var session
    @AppStorage("sidebar.hidden") private var hiddenRaw = ""

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: Binding(get: { Optional(model.section) }, set: { if let s = $0, s != model.section { model.section = s } })) {
                Section {
                    row(.home)
                    row(.all, count: model.count(.all))
                    row(.new, count: model.count(.new), highlight: true)
                    row(.favorites, count: model.count(.favorites))
                }
                Section("Работа") {
                    row(.sources, alert: model.sources.contains { $0.consecutiveFailures > 0 || $0.status != "ok" })
                    row(.runs)
                    row(.archive, count: model.count(.archive))
                    row(.excluded, count: model.count(.excluded))
                }
                if !model.allSources.isEmpty {
                    Section("Источники лидов") {
                        ForEach(model.allSources, id: \.self) { src in
                            Button {
                                model.section = .all
                                model.filter.source = model.filter.source == src ? nil : src
                            } label: {
                                HStack {
                                    SourceBadge(source: src)
                                    Spacer()
                                    if model.filter.source == src { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                Menu("Показывать разделы") {
                    ForEach([NavSection.home, .new, .favorites, .sources, .runs, .archive, .excluded]) { s in
                        Toggle(s.title, isOn: Binding(get: { !hidden.contains(s.rawValue) }, set: { show in
                            var h = hidden
                            if show { h.remove(s.rawValue) } else { h.insert(s.rawValue) }
                            hiddenRaw = h.sorted().joined(separator: ",")
                        }))
                    }
                }
            }
            Divider()
            footer
        }
    }

    @ViewBuilder
    private func row(_ s: NavSection, count: Int? = nil, highlight: Bool = false, alert: Bool = false) -> some View {
        if !hidden.contains(s.rawValue) {
            Label {
                HStack {
                    Text(s.title).appFont(13)
                    Spacer()
                    if alert { Circle().fill(.orange).frame(width: 6, height: 6) }
                    if let count, count > 0 {
                        if highlight {
                            Text("\(count)").appFont(10.5, .semibold).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.tint))
                        } else {
                            Text("\(count)").appFont(11.5).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } icon: { Image(systemName: s.icon) }
            .tag(s)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 22 * look.scale)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).appFont(12, .semibold)
                if model.searching {
                    Text(model.searchProgress ?? "Идёт поиск…").appFont(11).foregroundStyle(.secondary)
                } else {
                    Text(model.lastSearchAt.map { "Поиск: \($0.shortRelative)" } ?? "Поиск ещё не запускался")
                        .appFont(11).foregroundStyle(.secondary)
                }
                if let sync = session.sync {
                    Label(sync.summary, systemImage: sync.icon).appFont(11).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer()
            if model.searching { ProgressView().controlSize(.small) }
            Menu {
                Button("Настройки…") { openSettings() }
                if let sync = session.sync { Button("Синхронизировать сейчас") { sync.syncNow() } }
                Divider()
                Button("Выйти") { session.logout() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .scaledPadding(.horizontal, 12)
        .frame(height: 52 * look.scale)
    }
}
