import Foundation
import LeadGenCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Запись RSS или Atom.
public struct FeedEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var link: String
    public var summary: String
    public var published: Date?
    public var category: String?
}

/// Разбор RSS 2.0 и Atom без сторонних библиотек.
public final class FeedParser: NSObject, XMLParserDelegate {
    private var entries: [FeedEntry] = []
    private var current: [String: String]?
    private var text = ""
    private var failed = false

    public static func parse(_ data: Data) -> [FeedEntry]? {
        let p = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        let ok = parser.parse()
        if !ok && p.entries.isEmpty { return nil }
        return p.entries
    }

    private static func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = Self.local(elementName)
        if name == "item" || name == "entry" {
            current = [:]
        } else if current != nil, name == "link", let href = attributes["href"] {
            // Atom: <link rel="alternate" href="…"/>
            let rel = attributes["rel"] ?? "alternate"
            if rel == "alternate" && current?["link"] == nil { current?["link"] = href }
        } else if current != nil, name == "category", let term = attributes["term"], current?["category"] == nil {
            current?["category"] = term
        }
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        guard var cur = current else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item", "entry":
            let id = cur["guid"] ?? cur["id"] ?? cur["link"] ?? cur["title"] ?? ""
            let summary = cur["description"] ?? cur["summary"] ?? cur["encoded"] ?? cur["content"] ?? ""
            let date = Self.date(cur["pubdate"] ?? cur["published"] ?? cur["updated"] ?? cur["date"])
            entries.append(FeedEntry(id: id, title: cur["title"] ?? "", link: cur["link"] ?? "",
                                     summary: summary, published: date, category: cur["category"]))
            current = nil
            return
        case "title", "guid", "id", "description", "summary", "encoded", "content", "pubdate", "published", "updated", "date":
            if cur[name] == nil, !value.isEmpty { cur[name] = value }
        case "link":
            if cur["link"] == nil, !value.isEmpty { cur["link"] = value }
        case "category":
            if cur["category"] == nil, !value.isEmpty { cur["category"] = value }
        default:
            break
        }
        current = cur
        text = ""
    }

    private static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                                                  "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = $0
        return f
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = ISODate.parse(raw) { return d }
        for f in rfc822 { if let d = f.date(from: raw) { return d } }
        return nil
    }
}
