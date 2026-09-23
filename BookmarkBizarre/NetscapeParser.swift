import Foundation

// ============================================================================
// NetscapeParser.swift — reads NETSCAPE-Bookmark-file-1, the format every
// browser has exported since 1994. It is almost-HTML but NOT parseable as
// XML/HTML: <DT> and <p> are never closed, so a tree parser either chokes or
// silently reshuffles nesting. Browsers re-import it with a line scanner that
// tracks <DL> depth — this parser does the same thing for the same reason.
// ============================================================================

// MARK: - Parse output

/// A folder from an <H3> line. IDs are assigned in document order and become
/// the DB primary keys directly, so the tree round-trips without remapping.
struct ParsedFolder {
    let id: Int
    let parentID: Int?        // nil = sits under the document root
    let name: String
    let depth: Int            // 1 = "Bookmarks Bar" tier
    let addDate: Int?
    let lastModified: Int?
    let isToolbar: Bool
}

/// A bookmark from an <A> line, URL already broken into components.
/// Decomposition happens here — while we still know the source line — not
/// inside a DB transaction where a bad URL would be anonymous.
struct ParsedBookmark {
    let folderID: Int?
    let position: Int
    let title: String
    let url: String
    let scheme: String?
    let host: String?
    let path: String?
    let query: String?
    let fragment: String?
    let normURL: String
    let addDate: Int?
    let lastModified: Int?
    let iconURI: String?
    let tags: String?
    let requiresVPN: Bool
}

struct ParseResult {
    var folders: [ParsedFolder] = []
    var bookmarks: [ParsedBookmark] = []
    var skippedLines = 0      // <DT> lines that matched neither pattern — counted, never guessed at
}

// MARK: - Parser

enum NetscapeParser {

    // Real-world exports put exactly one folder or link per line. A tag split
    // across lines is rare enough (and ambiguous enough) that we refuse it and
    // count it in skippedLines rather than stitch lines back together and risk
    // marrying an HREF to the wrong title.
    private static let folderRe = try! NSRegularExpression(
        pattern: #"<DT[^>]*>\s*<H3([^>]*)>(.*?)</H3>"#, options: [.caseInsensitive])
    private static let linkRe = try! NSRegularExpression(
        pattern: #"<DT[^>]*>\s*<A([^>]*)>(.*?)</A>"#, options: [.caseInsensitive])
    private static let attrRe = try! NSRegularExpression(
        pattern: #"([A-Za-z_-]+)="([^"]*)""#)

    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        // Stack of the current folder path. nil entries are anonymous <DL>s
        // (the document root); folder ids are pushed when their <DL> opens.
        var stack: [Int?] = []
        // The H3 we just saw — adopted by the NEXT <DL>, which in this format
        // always arrives on a following line.
        var pendingFolder: Int? = nil
        var nextFolderID = 1
        var position = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = folderRe.firstMatch(in: line, range: full) {
                let attrs = attributes(in: ns.substring(with: m.range(at: 1)))
                result.folders.append(ParsedFolder(
                    id: nextFolderID,
                    parentID: stack.last.flatMap { $0 },
                    name: decodeEntities(ns.substring(with: m.range(at: 2))),
                    depth: stack.count,   // root <DL> is already on the stack → top-level = 1
                    addDate: attrs["add_date"].flatMap(Int.init),
                    lastModified: attrs["last_modified"].flatMap(Int.init),
                    isToolbar: attrs["personal_toolbar_folder"] == "true"))
                pendingFolder = nextFolderID
                nextFolderID += 1
            } else if let m = linkRe.firstMatch(in: line, range: full) {
                let attrs = attributes(in: ns.substring(with: m.range(at: 1)))
                guard let href = attrs["href"], !href.isEmpty else {
                    result.skippedLines += 1
                    continue
                }
                let parts = URLParts(of: href)
                result.bookmarks.append(ParsedBookmark(
                    folderID: stack.last.flatMap { $0 },
                    position: position,
                    title: decodeEntities(ns.substring(with: m.range(at: 2))),
                    url: href,
                    scheme: parts.scheme,
                    host: parts.host,
                    path: parts.path,
                    query: parts.query,
                    fragment: parts.fragment,
                    normURL: parts.normalized,
                    addDate: attrs["add_date"].flatMap(Int.init),
                    lastModified: attrs["last_modified"].flatMap(Int.init),
                    iconURI: attrs["icon"],
                    tags: attrs["tags"],
                    requiresVPN: VPNHeuristic.requiresVPN(host: parts.host)))
                position += 1
            } else if line.range(of: "</DL", options: .caseInsensitive) != nil {
                if !stack.isEmpty { stack.removeLast() }
            } else if line.range(of: "<DL", options: .caseInsensitive) != nil {
                // A <DL> belongs to the H3 right before it. A bare <DL> (the
                // document root) has no pending folder and keeps the current
                // context, so root-level links land on folderID nil.
                stack.append(pendingFolder ?? stack.last.flatMap { $0 })
                pendingFolder = nil
            } else if line.range(of: "<DT", options: .caseInsensitive) != nil {
                result.skippedLines += 1
            }
            // <DD> descriptions, <META>, <TITLE>, <H1> fall through untouched.
        }
        return result
    }

    /// Attribute blob → dict with lowercased keys, values entity-decoded.
    /// ICON values are multi-KB data: URIs; the regex is anchored on quotes so
    /// they pass through in one match without backtracking pain.
    private static func attributes(in blob: String) -> [String: String] {
        var out: [String: String] = [:]
        let ns = blob as NSString
        for m in attrRe.matches(in: blob, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1)).lowercased()] =
                decodeEntities(ns.substring(with: m.range(at: 2)))
        }
        return out
    }

    // MARK: Entity decoding

    /// Single-pass &entity; decoder. Chained replacingOccurrences is the
    /// classic trap here — decoding &amp;lt; twice yields "<" when the author
    /// wrote "&lt;". One pass over the string can't double-decode.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 10,   // real entities are short; a bare & in a URL is not one
               let ch = entityChar(String(s[s.index(after: i)..<semi])) {
                out.append(ch)
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func entityChar(_ e: String) -> Character? {
        switch e.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            if e.hasPrefix("#x") || e.hasPrefix("#X"),
               let v = UInt32(e.dropFirst(2), radix: 16), let sc = Unicode.Scalar(v) {
                return Character(sc)
            }
            if e.hasPrefix("#"), let v = UInt32(e.dropFirst()), let sc = Unicode.Scalar(v) {
                return Character(sc)
            }
            return nil   // unknown entity: leave the source text alone
        }
    }
}

// MARK: - URL decomposition

/// URL → components, with a fallback for the malformed URLs every real
/// bookmark file contains (spaces, stray unicode, garbage schemes).
/// URLComponents rejects those outright; the fallback still recovers
/// scheme + host so the inventory can COUNT them instead of dropping rows.
struct URLParts {
    var scheme: String?
    var host: String?
    var path: String?
    var query: String?
    var fragment: String?
    var normalized: String

    init(of raw: String) {
        if let c = URLComponents(string: raw) {
            scheme = c.scheme?.lowercased()
            host = c.host?.lowercased()
            path = c.path.isEmpty ? nil : c.path
            query = c.query
            fragment = c.fragment
        } else {
            if let m = raw.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) {
                scheme = String(raw[m].dropLast()).lowercased()
            }
            // host = whatever sits between // and the next / ? #, with any
            // user:pass@ and :port peeled off
            if let m = raw.range(of: #"//[^/?#]+"#, options: .regularExpression) {
                var h = String(raw[m].dropFirst(2))
                if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
                if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
                host = h.lowercased().isEmpty ? nil : h.lowercased()
            }
        }
        normalized = Self.normalize(raw: raw, scheme: scheme, host: host, path: path, query: query)
    }

    /// Query params that identify a CLICK, not a page — two saves of the same
    /// article with different utm_ trails are the same bookmark.
    private static let trackingParams: Set<String> =
        ["gclid", "gclsrc", "fbclid", "mc_cid", "mc_eid", "igshid", "ref_src"]

    static func normalize(raw: String, scheme: String?, host: String?, path: String?, query: String?) -> String {
        // No host (javascript:, data:, mailto:) → the raw string IS the
        // identity; lowercasing a bookmarklet would corrupt it.
        guard let scheme, let host else {
            return raw.trimmingCharacters(in: .whitespaces)
        }
        var p = path ?? ""
        if p == "/" { p = "" }   // example.com and example.com/ are the same save
        var q = ""
        if let query {
            let kept = query.split(separator: "&").filter { pair in
                let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                return !(name.hasPrefix("utm_") || trackingParams.contains(name))
            }.map(String.init).sorted()   // sorted → param order can't split a dup group
            if !kept.isEmpty { q = "?" + kept.joined(separator: "&") }
        }
        return "\(scheme)://\(host)\(p)\(q)"   // fragment deliberately dropped: same page, different scroll
    }
}

// MARK: - VPN heuristic

/// Import-time guess at "not reachable from the open internet". Pure host
/// pattern matching — the app never probes these hosts. The per-bookmark UI
/// toggle overrides the guess and is never re-clobbered, because import runs
/// exactly once per file.
enum VPNHeuristic {
    static func requiresVPN(host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        if !host.contains(".") { return true }                    // bare intranet name
        for suffix in [".local", ".internal", ".corp", ".lan"] where host.hasSuffix(suffix) {
            return true
        }
        if host == "nyp.org" || host.hasSuffix(".nyp.org") { return true }  // J's corporate estate
        // RFC1918 / loopback literals
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            if octets[0] == 10 || octets[0] == 127 { return true }
            if octets[0] == 192 && octets[1] == 168 { return true }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        }
        return false
    }
}
