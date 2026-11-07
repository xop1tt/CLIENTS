import AppKit
import LeadGenCore
import SwiftUI

/// Узнаваемые значки сервисов для визуальной ориентации: упрощённые фирменные формы и цвета,
/// нарисованные векторно (без файлов логотипов).
struct ServiceIcon: View {
    enum Kind: Equatable { case drive(DriveService), mail(MailProvider), mailApp }
    let kind: Kind
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            switch kind {
            case .drive(.googleDrive): GoogleDriveMark().padding(size * 0.14)
            case .drive(.dropbox): DropboxMark().fill(Color(hex: 0x0061FF)).padding(size * 0.12)
            case .drive(.oneDrive): symbol("cloud.fill", Color(hex: 0x0078D4))
            case .drive(.yandexDisk): letter("Я", bg: Color(hex: 0xFC3F1D))
            case .drive(.mega): Circle().fill(Color(hex: 0xD9272E)).overlay(Text("M").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.white)).padding(size * 0.06)
            case .drive(.pCloud): tile(Color(hex: 0x17BED0)) { Image(systemName: "cloud.fill").font(.system(size: size * 0.46)).foregroundStyle(.white) }
            case .drive(.webdav): tile(Color(hex: 0x6E7681)) { Image(systemName: "server.rack").font(.system(size: size * 0.44)).foregroundStyle(.white) }
            case .mail(.gmail): GmailMark().padding(size * 0.12)
            case .mail(.yandex): letter("Я", bg: Color(hex: 0xFC3F1D))
            case .mail(.mailru): letter("@", bg: Color(hex: 0x005FF9))
            case .mail(.icloud): symbol("icloud.fill", Color(hex: 0x3693F3))
            case .mail(.custom): tile(Color(hex: 0x6E7681)) { Image(systemName: "envelope.fill").font(.system(size: size * 0.42)).foregroundStyle(.white) }
            case .mailApp: tile(Color(hex: 0x1E88E5)) { Image(systemName: "envelope.fill").font(.system(size: size * 0.42)).foregroundStyle(.white) }
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.separator))
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: size * 0.52)).foregroundStyle(color)
    }

    private func letter(_ s: String, bg: Color) -> some View {
        tile(bg) { Text(s).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white) }
    }

    private func tile<C: View>(_ bg: Color, @ViewBuilder _ content: () -> C) -> some View {
        RoundedRectangle(cornerRadius: size * 0.2).fill(bg).overlay(content()).padding(size * 0.08)
    }
}

/// Треугольник из трёх полос: синяя снизу, зелёная слева, жёлтая справа.
private struct GoogleDriveMark: View {
    var body: some View {
        ZStack {
            Polygon(points: [CGPoint(x: 0.34, y: 0.64), CGPoint(x: 1.0, y: 0.64), CGPoint(x: 0.83, y: 0.93), CGPoint(x: 0.17, y: 0.93)])
                .fill(Color(hex: 0x2684FC))
            Polygon(points: [CGPoint(x: 0.33, y: 0.08), CGPoint(x: 0.50, y: 0.38), CGPoint(x: 0.17, y: 0.93), CGPoint(x: 0.0, y: 0.64)])
                .fill(Color(hex: 0x00AC47))
            Polygon(points: [CGPoint(x: 0.33, y: 0.08), CGPoint(x: 0.67, y: 0.08), CGPoint(x: 1.0, y: 0.64), CGPoint(x: 0.66, y: 0.64)])
                .fill(Color(hex: 0xFFBA00))
        }
    }
}

/// Многоугольник по точкам в долях от размера (0…1).
private struct Polygon: Shape {
    let points: [CGPoint]
    func path(in r: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: r.minX + first.x * r.width, y: r.minY + first.y * r.height))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)) }
        path.closeSubpath()
        return path
    }
}

/// Пять ромбов, как у Dropbox.
private struct DropboxMark: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        func diamond(_ cx: CGFloat, _ cy: CGFloat, _ hw: CGFloat, _ hh: CGFloat) {
            let x = r.minX + cx * r.width, y = r.minY + cy * r.height
            path.move(to: CGPoint(x: x, y: y - hh * r.height))
            path.addLine(to: CGPoint(x: x + hw * r.width, y: y))
            path.addLine(to: CGPoint(x: x, y: y + hh * r.height))
            path.addLine(to: CGPoint(x: x - hw * r.width, y: y))
            path.closeSubpath()
        }
        diamond(0.25, 0.22, 0.24, 0.17)
        diamond(0.75, 0.22, 0.24, 0.17)
        diamond(0.25, 0.56, 0.24, 0.17)
        diamond(0.75, 0.56, 0.24, 0.17)
        diamond(0.5, 0.84, 0.22, 0.14)
        return path
    }
}

/// Конверт с красной «M».
private struct GmailMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0.08 * w, y: 0.85 * h))
                    p.addLine(to: CGPoint(x: 0.08 * w, y: 0.2 * h))
                    p.addLine(to: CGPoint(x: 0.5 * w, y: 0.55 * h))
                    p.addLine(to: CGPoint(x: 0.92 * w, y: 0.2 * h))
                    p.addLine(to: CGPoint(x: 0.92 * w, y: 0.85 * h))
                }
                .stroke(Color(hex: 0xEA4335), style: StrokeStyle(lineWidth: w * 0.16, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
