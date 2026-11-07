import AppKit
import XCTest

/// Значок приложения: один, тёмный, буква C по центру; в коде нет подмены значка в Dock.
///
/// Раньше тёмный значок ставился в Dock из кода, а при выходе из приложения Dock показывал значок из
/// пакета (светлый). Теперь значок один и тёмный, поэтому подмены быть не должно.
final class IconTests: XCTestCase {
    private var macos: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func bitmap() throws -> NSBitmapImageRep {
        let url = macos.appendingPathComponent("Resources/AppIcon-1024.png")
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    func testLetterIsCenteredAndInsideTheTile() throws {
        let rep = try bitmap()
        XCTAssertEqual(rep.pixelsWide, 1024); XCTAssertEqual(rep.pixelsHigh, 1024)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent > 0.78 && c.blueComponent - c.redComponent > 0.31 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "буква на значке есть")
        XCTAssertEqual(Double(minY + maxY) / 2, 511.5, accuracy: 2, "по вертикали ровно по центру")
        XCTAssertEqual(Double(minX + maxX) / 2, 511.5, accuracy: 2, "по горизонтали по центру")
        let pads = [minX - 100, 924 - maxX, minY - 100, 924 - maxY]
        XCTAssertTrue(pads.allSatisfy { (100...200).contains($0) }, "небольшой отступ от краёв плитки: \(pads)")
    }

    func testTileIsDark() throws {
        let rep = try bitmap()
        for (x, y) in [(130, 512), (512, 130), (512, 900), (900, 512), (200, 200)] {
            let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertLessThan((c.redComponent + c.greenComponent + c.blueComponent) / 3, 0.24, "плитка тёмная в \(x),\(y)")
        }
    }

    func testNoLightVariantAndNoDockOverride() throws {
        let resources = try FileManager.default.contentsOfDirectory(atPath: macos.appendingPathComponent("Resources").path)
        XCTAssertFalse(resources.contains { $0.contains("Dark") }, "значок один")
        let sources = macos.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"applicationIconImage\s*="#)
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                         "\(url.lastPathComponent): значок в Dock не подменяется")
        }
    }
}
