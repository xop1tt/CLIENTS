import LeadGenCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppearanceSettings.self) private var look

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240 * look.scale, max: 360)
        } detail: {
            ZStack(alignment: .bottom) {
                content
                    .inspector(isPresented: $model.inspectorShown) {
                        InspectorView()
                            .inspectorColumnWidth(min: 300, ideal: 380 * look.scale, max: 560)
                    }
                if let err = model.lastError {
                    Toast(text: err, isError: true) { model.lastError = nil }.padding(.bottom, 16)
                } else if let msg = model.lastMessage {
                    Toast(text: msg, isError: false) { model.lastMessage = nil }
                        .padding(.bottom, 16)
                        .task(id: msg) {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            if model.lastMessage == msg { model.lastMessage = nil }
                        }
                }
            }
        }
        .overlay {
            if let e = model.startupError {
                ContentUnavailableView("База недоступна", systemImage: "externaldrive.badge.exclamationmark", description: Text(e))
                    .background(.background)
            }
        }
        .task {
            if model.syncConfigured { await model.syncNow() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: DashboardView()
        case .sources: SourcesView()
        case .runs: RunsView()
        default: LeadsView()
        }
    }
}

/// Правая панель: содержимое зависит от раздела и выбранного объекта.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.section.isLeadList || model.section == .home {
                if let lead = model.selectedLead {
                    LeadInspector(lead: lead)
                } else if model.selection.count > 1 {
                    ContentUnavailableView("Выбрано: \(model.selection.count)", systemImage: "checklist",
                                           description: Text("Действия с выбранными — на панели над таблицей и в контекстном меню."))
                } else {
                    ContentUnavailableView("Лид не выбран", systemImage: "sidebar.right",
                                           description: Text("Выберите лид, чтобы увидеть оценку, контакты и черновик обращения."))
                }
            } else if model.section == .sources {
                SourcesInspector()
            } else {
                SyncInspector()
            }
        }
    }
}
