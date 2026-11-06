import Charts
import LeadGenCore
import SwiftUI

struct DashboardView: View {
    @Environment(\.appModel) private var model
    @Environment(\.look) private var look

    private var active: [LeadItem] { model.leads.filter { !$0.excluded && $0.data.relevance != .rejected } }
    private var newLeads: [LeadItem] { active.filter { !$0.seen && !$0.archived } }
    private var recent: [LeadItem] {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return active.filter { $0.discoveredAt >= from }
    }

    struct DayPoint: Identifiable {
        let id = UUID()
        let day: Date
        let kind: String
        let count: Int
    }

    private var daily: [DayPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [DayPoint] = []
        for offset in (0..<14).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let items = active.filter { cal.isDate($0.discoveredAt, inSameDayAs: day) }
            out.append(DayPoint(day: day, kind: "Организации", count: items.filter { $0.data.kind == .organization }.count))
            out.append(DayPoint(day: day, kind: "Заказы", count: items.filter { $0.data.kind == .order }.count))
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * look.scale) {
                kpis
                HStack(alignment: .top, spacing: 16 * look.scale) {
                    Card(title: "Новые с высокой оценкой", icon: "sparkles", trailing: "\(newLeads.count) новых") {
                        let top = newLeads.sorted { $0.data.score > $1.data.score }.prefix(6)
                        if top.isEmpty {
                            Text("Новых лидов нет").appFont(12.5).foregroundStyle(.secondary).scaledPadding(.all, 14)
                        }
                        ForEach(Array(top)) { l in
                            Button {
                                model.section = .new
                                model.selection = [l.id]
                                model.inspectorShown = true
                            } label: {
                                HStack(spacing: 10) {
                                    SourceBadge(source: l.data.source, showTitle: false)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(l.data.title).appFont(12.5, .medium).lineLimit(1)
                                        Text("\(l.data.kind.title) · \(SourceCatalog.title(l.data.source))").appFont(11).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    ScoreView(score: l.data.score)
                                    Text(l.discoveredAt.shortRelative).appFont(11.5).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .scaledPadding(.horizontal, 14)
                            .scaledPadding(.vertical, 8)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Card(title: "Источники", icon: "cylinder.split.1x2", trailing: "поиск на этом Mac") {
                        if model.sources.isEmpty {
                            Text("Появятся после первого поиска").appFont(12.5).foregroundStyle(.secondary).scaledPadding(.all, 14)
                        }
                        ForEach(model.sources) { s in
                            HStack(spacing: 10) {
                                SourceBadge(source: s.source, showTitle: false)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(SourceCatalog.title(s.source)).appFont(12.5, .medium)
                                    Text(sourceLine(s)).appFont(11).foregroundStyle(s.consecutiveFailures > 0 ? .orange : .secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(recent.filter { $0.data.source == s.source }.count)").appFont(12.5).monospacedDigit()
                            }
                            .scaledPadding(.horizontal, 14)
                            .scaledPadding(.vertical, 8)
                            Divider()
                        }
                    }
                    .frame(maxWidth: 420 * look.scale)
                }
                Card(title: "Обнаружение за 14 дней", icon: "chart.bar") {
                    Chart(daily) { p in
                        BarMark(x: .value("День", p.day, unit: .day), y: .value("Лидов", p.count))
                            .foregroundStyle(by: .value("Тип", p.kind))
                            .cornerRadius(3)
                    }
                    .chartForegroundStyleScale(["Организации": look.accent.color, "Заказы": Color.blue.opacity(0.7)])
                    .frame(height: 180 * look.scale)
                    .scaledPadding(.all, 14)
                }
                if !model.pipelineErrors.isEmpty {
                    Card(title: "Последние ошибки поиска", icon: "exclamationmark.triangle") {
                        ForEach(model.pipelineErrors.prefix(5)) { e in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(.orange).frame(width: 6, height: 6).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(SourceCatalog.title(e.module)).appFont(12.5, .medium)
                                    Text(e.message).appFont(11.5).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if let at = e.at { Text(at.shortRelative).appFont(11.5).foregroundStyle(.secondary) }
                            }
                            .scaledPadding(.horizontal, 14)
                            .scaledPadding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .scaledPadding(.all, 20)
        }
        .navigationTitle("Главная")
    }

    private var kpis: some View {
        let avg = recent.isEmpty ? 0 : recent.map(\.data.score).reduce(0, +) / Double(recent.count)
        return HStack(spacing: 0) {
            kpi("Новые", "\(newLeads.count)", "не просмотрены")
            Divider()
            kpi("Всего в базе", "\(active.count)", "\(model.count(.favorites)) в избранном")
            Divider()
            kpi("Средняя оценка за 7 дней", recent.isEmpty ? "—" : "\(Int(avg.rounded()))", "\(recent.count) лидов")
            Divider()
            kpi("Исключено", "\(model.count(.excluded))", "по вашим правилам")
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func kpi(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).appFont(11.5).foregroundStyle(.secondary)
            Text(value).appFont(22, .semibold).monospacedDigit()
            Text(note).appFont(11).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 12)
    }

    private func sourceLine(_ s: SourceState) -> String {
        if s.consecutiveFailures > 0 { return "Ошибок подряд: \(s.consecutiveFailures)" + (s.lastError.map { " · \($0)" } ?? "") }
        if let at = s.lastSuccessAt { return "Работает · \(at.shortRelative)" }
        return s.status
    }
}
