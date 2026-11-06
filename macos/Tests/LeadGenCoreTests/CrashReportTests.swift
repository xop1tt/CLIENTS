import Foundation
import XCTest
@testable import LeadGenCore

final class CrashReportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testOnlyOwnReportsAreFound() throws {
        for name in ["LeadGenerator-2026-11-06-120000.ips", "LeadGenerator_2026-11-06-120500.hang",
                     "Safari-2026-11-06-120000.ips", "LeadGenerator-notes.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let found = CrashReports.find(in: [dir, dir.appendingPathComponent("missing")])
        XCTAssertEqual(Set(found.map { $0.url.lastPathComponent }),
                       ["LeadGenerator-2026-11-06-120000.ips", "LeadGenerator_2026-11-06-120500.hang"])
        XCTAssertEqual(found.first { $0.url.pathExtension == "hang" }?.kind, "Зависание")
        XCTAssertTrue(CrashReports.find(in: [dir], newerThan: Date().addingTimeInterval(60)).isEmpty)
    }

    func testSummaryOfIPS() {
        let header = #"{"app_name":"LeadGenerator","app_version":"1.0.3","os_version":"macOS 15.1 (24B83)","timestamp":"2026-11-06 12:00:00.00 +0300"}"#
        let body = #"""
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":0,
         "usedImages":[{"name":"SwiftUI"},{"name":"LeadGenerator"}],
         "threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"EnvironmentValues.subscript.getter"},{"imageIndex":1,"imageOffset":4096}]}]}
        """#.replacingOccurrences(of: "\n", with: "")
        let s = CrashReports.summary(of: header + "\n" + body)
        XCTAssertTrue(s.contains("Версия: 1.0.3"))
        XCTAssertTrue(s.contains("EXC_BREAKPOINT, SIGTRAP"))
        XCTAssertTrue(s.contains("0  SwiftUI  EnvironmentValues.subscript.getter"))
        XCTAssertTrue(s.contains("1  LeadGenerator  +0x1000"))
    }

    func testSummaryFallsBackToText() {
        XCTAssertEqual(CrashReports.summary(of: "Process: LeadGenerator\nCrashed Thread: 0", fallbackLimit: 7), "Process")
    }

    func testRedaction() {
        let s = CrashReports.redact("/Users/maksim/Library/x and maksim", home: "/Users/maksim", user: "maksim")
        XCTAssertEqual(s, "~/Library/x and <user>")
    }

    func testIssueURL() throws {
        let url = CrashReports.issueURL(repository: "o/r", title: "Вылет", body: String(repeating: "a", count: 50) + " C++", maxBody: 40)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.path, "/o/r/issues/new")
        XCTAssertEqual(c.queryItems?.first { $0.name == "title" }?.value, "Вылет")
        let body = try XCTUnwrap(c.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.hasPrefix(String(repeating: "a", count: 40)))
        XCTAssertTrue(body.contains("текст обрезан"))
        XCTAssertFalse(url.absoluteString.contains("+"))
    }

    func testErrorLogKeepsLastLines() {
        let log = dir.appendingPathComponent("errors.log")
        for i in 1...5 { ErrorLog.append("ошибка \(i)\nвторая строка", to: log, keep: 3) }
        let lines = ErrorLog.recent(10, from: log)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.last!.hasSuffix("ошибка 5 вторая строка"))
        ErrorLog.clear(log)
        XCTAssertTrue(ErrorLog.recent(10, from: log).isEmpty)
    }
}
