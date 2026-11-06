import AppKit
import SwiftUI

/// Тема, шрифт и масштаб интерфейса. Хранятся в UserDefaults, применяются ко всем окнам сразу.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum Density: String, CaseIterable, Identifiable {
    case compact, regular, comfortable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "Компактная"
        case .regular: return "Обычная"
        case .comfortable: return "Просторная"
        }
    }
    var rowPadding: CGFloat {
        switch self {
        case .compact: return 1
        case .regular: return 4
        case .comfortable: return 8
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case emerald, blue, violet, amber, graphite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .emerald: return "Изумруд"
        case .blue: return "Синий"
        case .violet: return "Фиолетовый"
        case .amber: return "Янтарный"
        case .graphite: return "Графит"
        }
    }
    var color: Color {
        switch self {
        case .emerald: return Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0.21, green: 0.76, blue: 0.65, alpha: 1) : NSColor(srgbRed: 0.06, green: 0.48, blue: 0.41, alpha: 1) })
        case .blue: return Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0.47, green: 0.65, blue: 0.94, alpha: 1) : NSColor(srgbRed: 0.18, green: 0.44, blue: 0.82, alpha: 1) })
        case .violet: return Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0.66, green: 0.57, blue: 0.94, alpha: 1) : NSColor(srgbRed: 0.45, green: 0.33, blue: 0.79, alpha: 1) })
        case .amber: return Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0.88, green: 0.66, blue: 0.31, alpha: 1) : NSColor(srgbRed: 0.72, green: 0.47, blue: 0.12, alpha: 1) })
        case .graphite: return Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.25, alpha: 1) })
        }
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

@Observable
final class AppearanceSettings {
    static let systemFont = "Системный"
    static let scaleRange: ClosedRange<Double> = 0.8...1.5
    static let scaleSteps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.5]

    private let defaults = UserDefaults.standard

    var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: "appearance.theme"); apply() } }
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "appearance.font") } }
    var monoFamily: String { didSet { defaults.set(monoFamily, forKey: "appearance.mono") } }
    var scale: Double { didSet { defaults.set(scale, forKey: "appearance.scale") } }
    var density: Density { didSet { defaults.set(density.rawValue, forKey: "appearance.density") } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "appearance.accent") } }

    init() {
        theme = ThemeMode(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .system
        fontFamily = defaults.string(forKey: "appearance.font") ?? Self.systemFont
        monoFamily = defaults.string(forKey: "appearance.mono") ?? Self.systemFont
        let s = defaults.double(forKey: "appearance.scale")
        scale = s == 0 ? 1.0 : min(max(s, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        density = Density(rawValue: defaults.string(forKey: "appearance.density") ?? "") ?? .regular
        accent = AccentChoice(rawValue: defaults.string(forKey: "appearance.accent") ?? "") ?? .emerald
    }

    /// Тема применяется на уровне приложения, чтобы её получили и окно настроек, и меню.
    func apply() {
        let appearance = theme.nsAppearance
        DispatchQueue.main.async { NSApp?.appearance = appearance }
    }

    func zoomIn() { scale = Self.scaleSteps.first { $0 > scale + 0.001 } ?? Self.scaleRange.upperBound }
    func zoomOut() { scale = Self.scaleSteps.last { $0 < scale - 0.001 } ?? Self.scaleRange.lowerBound }
    func resetZoom() { scale = 1.0 }

    var controlSize: ControlSize {
        switch scale {
        case ..<0.95: return .small
        case 1.2...: return .large
        default: return .regular
        }
    }

    /// Все семейства шрифтов, установленные на Mac.
    static var installedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
    }

    static let recommended = ["SF Pro", "Inter", "IBM Plex Sans", "Golos Text", "Onest", "PT Sans", "Helvetica Neue", "Avenir Next"]
    static let recommendedMono = ["SF Mono", "Menlo", "JetBrains Mono", "IBM Plex Mono"]

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        let family = mono ? monoFamily : fontFamily
        let s = size * scale
        if family == Self.systemFont || family.isEmpty {
            return mono ? .system(size: s, weight: weight, design: .monospaced) : .system(size: s, weight: weight)
        }
        return .custom(family, size: s).weight(weight)
    }
}

// MARK: - Использование в представлениях

/// Шрифт с учётом выбранного семейства и масштаба интерфейса.
struct AppFont: ViewModifier {
    @Environment(AppearanceSettings.self) private var look
    let size: CGFloat
    let weight: Font.Weight
    let mono: Bool
    func body(content: Content) -> some View { content.font(look.font(size, weight, mono: mono)) }
}

extension View {
    func appFont(_ size: CGFloat = 13, _ weight: Font.Weight = .regular, mono: Bool = false) -> some View {
        modifier(AppFont(size: size, weight: weight, mono: mono))
    }
}

/// Отступ, умноженный на масштаб интерфейса.
struct Scaled: ViewModifier {
    @Environment(AppearanceSettings.self) private var look
    let edges: Edge.Set
    let value: CGFloat
    func body(content: Content) -> some View { content.padding(edges, value * look.scale) }
}

extension View {
    func scaledPadding(_ edges: Edge.Set = .all, _ value: CGFloat) -> some View { modifier(Scaled(edges: edges, value: value)) }
}

/// Корневой модификатор окна: шрифт по умолчанию, акцент, размер контролов.
/// Корневой модификатор окна. Получает настройки параметром, а не из окружения:
/// модификатор стоит снаружи `.environment(look)`, и чтение `@Environment` здесь
/// приводило к падению при запуске (значения в окружении ещё нет).
struct LookRoot: ViewModifier {
    let look: AppearanceSettings
    func body(content: Content) -> some View {
        content
            .environment(look)
            .font(look.font(13))
            .tint(look.accent.color)
            .controlSize(look.controlSize)
    }
}
