import Foundation
import XCTest
@testable import LeadGenCore

final class AppVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AppVersion("v1.0.4")?.parts, [1, 0, 4])
        XCTAssertEqual(AppVersion("1.2")?.parts, [1, 2])
        XCTAssertEqual(AppVersion("1.0.5-beta.1")?.parts, [1, 0, 5])
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("latest"))
    }

    func testComparison() {
        XCTAssertLessThan(AppVersion("1.0.4")!, AppVersion("1.0.5")!)
        XCTAssertLessThan(AppVersion("1.0.9")!, AppVersion("1.0.10")!)
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("2.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("1.0.5")! < AppVersion("1.0.4")!)
    }
}

final class UpdatesTests: XCTestCase {
    static let digest = String(repeating: "ab", count: 32)

    func release(tag: String = "v1.0.5", draft: Bool = false, prerelease: Bool = false,
                 assets: String? = nil) throws -> ReleaseInfo {
        let list = assets ?? """
        [{"name": "Lead-Generator-\(tag)-macOS.dmg", "browser_download_url": "https://example.com/a.dmg",
          "size": 100, "digest": "sha256:\(Self.digest)"},
         {"name": "Lead-Generator-\(tag)-macOS.dmg.sha256", "browser_download_url": "https://example.com/a.sha256",
          "size": 90, "digest": null}]
        """
        let json = """
        {"tag_name": "\(tag)", "name": "Lead Generator \(tag)", "body": "Что нового",
         "html_url": "https://github.com/xop1tt/CLIENTS/releases/tag/\(tag)",
         "draft": \(draft), "prerelease": \(prerelease), "assets": \(list)}
        """
        return try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
    }

    func testNewerReleaseIsOffered() throws {
        let u = try XCTUnwrap(Updates.update(from: release(), current: AppVersion("1.0.4")!))
        XCTAssertEqual(u.version.description, "1.0.5")
        XCTAssertEqual(u.dmg.name, "Lead-Generator-v1.0.5-macOS.dmg")
        XCTAssertEqual(u.checksumFile?.name, "Lead-Generator-v1.0.5-macOS.dmg.sha256")
        XCTAssertEqual(u.expectedDigest, Self.digest)
        XCTAssertEqual(u.notes, "Что нового")
    }

    func testSameOrOlderIsIgnored() throws {
        XCTAssertNil(Updates.update(from: try release(), current: AppVersion("1.0.5")!))
        XCTAssertNil(Updates.update(from: try release(), current: AppVersion("1.1")!))
    }

    func testDraftsAndPrereleasesAreIgnored() throws {
        XCTAssertNil(Updates.update(from: try release(draft: true), current: AppVersion("1.0.4")!))
        XCTAssertNil(Updates.update(from: try release(prerelease: true), current: AppVersion("1.0.4")!))
    }

    func testReleaseWithoutInstallerIsIgnored() throws {
        let r = try release(assets: """
        [{"name": "notes.txt", "browser_download_url": "https://example.com/n.txt"}]
        """)
        XCTAssertNil(Updates.update(from: r, current: AppVersion("1.0.4")!))
    }

    func testBadDigestFallsBackToChecksumFile() throws {
        let r = try release(assets: """
        [{"name": "Lead-Generator-v1.0.5-macOS.dmg", "browser_download_url": "https://example.com/a.dmg", "digest": "md5:123"}]
        """)
        let u = try XCTUnwrap(Updates.update(from: r, current: AppVersion("1.0.4")!))
        XCTAssertNil(u.expectedDigest)
        XCTAssertNil(u.checksumFile)
    }

    func testChecksumFile() {
        XCTAssertEqual(Updates.parseChecksumFile("\(Self.digest.uppercased())  Lead-Generator-v1.0.5-macOS.dmg\n"), Self.digest)
        XCTAssertNil(Updates.parseChecksumFile("not a checksum"))
    }

    func testSHA256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lg-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try Updates.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class FourPartVersionTests: XCTestCase {
    func testPatchOfPatchIsNewer() {
        XCTAssertEqual(AppVersion("v1.0.6.1")?.parts, [1, 0, 6, 1])
        XCTAssertLessThan(AppVersion("1.0.6")!, AppVersion("1.0.6.1")!)
        XCTAssertLessThan(AppVersion("1.0.6.1")!, AppVersion("1.0.7")!)
    }
}

final class RecentReleasesTests: XCTestCase {
    func testOnlyPublishedAndLimited() throws {
        let json = """
        [{"tag_name": "v1.0.8", "name": null, "draft": true, "prerelease": false, "assets": []},
         {"tag_name": "v1.0.7", "name": "Lead Generator 1.0.7", "draft": false, "prerelease": false, "assets": [],
          "published_at": "2026-11-06T21:00:00Z"},
         {"tag_name": "v1.0.7-beta", "name": "beta", "draft": false, "prerelease": true, "assets": []},
         {"tag_name": "v1.0.6.1", "name": "", "draft": false, "prerelease": false, "assets": []},
         {"tag_name": "v1.0.6", "name": "Lead Generator 1.0.6", "draft": false, "prerelease": false, "assets": []},
         {"tag_name": "v1.0.5", "name": "Lead Generator 1.0.5", "draft": false, "prerelease": false, "assets": []}]
        """
        let all = try JSONDecoder().decode([ReleaseInfo].self, from: Data(json.utf8))
        let recent = Updates.recent(from: all)
        XCTAssertEqual(recent.map(\.tagName), ["v1.0.7", "v1.0.6.1", "v1.0.6"])
        XCTAssertEqual(recent[0].title, "Lead Generator 1.0.7")
        XCTAssertEqual(recent[1].title, "v1.0.6.1")
        XCTAssertNotNil(recent[0].publishedDate)
        XCTAssertNil(recent[1].publishedDate)
    }
}
