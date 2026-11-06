import LeadGenCore
import SwiftUI

enum Palette {
    static func scoreColor(_ s: Double) -> Color {
        s >= 70 ? .green : s >= 45 ? .orange : .secondary
    }
    static let sourceColors: [String: Color] = [
        "fl_ru": Color(red: 0.25, green: 0.49, blue: 0.31),
        "telegram_channels": Color(red: 0.23, green: 0.56, blue: 0.84),
        "vk_communities": Color(red: 0.29, green: 0.44, blue: 0.65),
        "osm_organizations": Color(red: 0.48, green: 0.60, blue: 0.23),
    ]
}

/// Оценка: число + полоска.
struct ScoreView: View {
    @Environment(AppearanceSettings.self) private var look
    let score: Double
    var body: some View {
        HStack(spacing: 6 * look.scale) {
            Text("\(Int(score.rounded()))")
                .appFont(12.5, .semibold)
                .monospacedDigit()
                .foregroundStyle(Palette.scoreColor(score))
                .frame(minWidth: 20 * look.scale, alignment: .leading)
            Capsule().fill(.quaternary)
                .frame(width: 40 * look.scale, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.scoreColor(score)).frame(width: 40 * look.scale * min(score, 100) / 100, height: 4)
                }
        }
    }
}

/// Буквенный значок источника (без чужих логотипов).
struct SourceBadge: View {
    @Environment(AppearanceSettings.self) private var look
    let source: String
    var showTitle = true
    var body: some View {
        HStack(spacing: 6) {
            Text(String(SourceCatalog.title(source).prefix(2)).uppercased())
                .font(.system(size: 8.5 * look.scale, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16 * look.scale, height: 16 * look.scale)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.sourceColors[source] ?? .gray))
            if showTitle { Text(SourceCatalog.title(source)).appFont(12).foregroundStyle(.secondary) }
        }
    }
}

/// Небольшая метка.
struct Tag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .appFont(11, .medium)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
    }
}

/// Заголовок раздела в панелях.
struct PanelHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).appFont(11, .semibold).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).appFont(11).foregroundStyle(.tertiary) }
        }
    }
}

/// Карточка с рамкой.
struct Card<Content: View>: View {
    let title: String
    var icon: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(title).appFont(12.5, .semibold)
                Spacer()
                if let trailing { Text(trailing).appFont(11.5).foregroundStyle(.secondary) }
            }
            .scaledPadding(.horizontal, 14)
            .scaledPadding(.vertical, 10)
            Divider()
            content
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// Сообщение об ошибке или успехе внизу окна.
struct Toast: View {
    let text: String
    let isError: Bool
    let close: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(text).appFont(12.5).lineLimit(3)
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 560)
    }
}

extension Date {
    var shortRelative: String {
        let cal = Calendar.current
        let tf = DateFormatter(); tf.locale = Locale(identifier: "ru_RU")
        if cal.isDateInToday(self) { tf.dateFormat = "HH:mm"; return tf.string(from: self) }
        if cal.isDateInYesterday(self) { tf.dateFormat = "HH:mm"; return "Вчера, " + tf.string(from: self) }
        tf.dateFormat = cal.isDate(self, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return tf.string(from: self)
    }

    var fullRu: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy, HH:mm"
        return f.string(from: self)
    }
}

func durationText(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 60 ? "\(s / 60) мин \(s % 60) с" : "\(s) с"
}
