import Foundation
import SQLite3
import CryptoKit

// ============================================================================
// BrowserImport.swift — pull bookmarks straight out of installed browsers,
// no export step. Three vendors, three formats, three different traps:
//   Chrome family: JSON, timestamps in MICROSECONDS SINCE 1601 (FILETIME)
//   Firefox:       places.sqlite, µs since the UNIX epoch, and LOCKED while
//                  Firefox runs — always read a snapshot copy
//   Safari:        binary plist behind TCC — silently unreadable without
//                  Full Disk Access, so readability is probed up front
// Every vendor funnels into the same ParseResult → Importer.importParsed
// pipeline, so a pulled library is indistinguishable from a file import
// except for its source_kind/source_profile provenance.
// ============================================================================

// MARK: - Kinds & profiles

enum BrowserKind: String, CaseIterable {
    case chrome, edge, brave, firefox, safari

    var displayName: String {
        switch self {
        case .chrome:  return "Chrome"
        case .edge:    return "Edge"
        case .brave:   return "Brave"
        case .firefox: return "Firefox"
        case .safari:  return "Safari"
        }
    }

    /// SF Symbols only — shipping vendor logos means shipping vendor lawyers.
    var symbolName: String {
        switch self {
        case .chrome, .edge, .brave: return "globe"
        case .firefox:               return "flame"
        case .safari:                return "safari"
        }
    }
}

struct BrowserProfile: Identifiable, Hashable {
    let kind: BrowserKind
    let profileName: String     // "Default", "Profile 2", "default-release"…
    let bookmarkFileURL: URL
    let readable: Bool          // open-probe result; false = show why, don't crash

    var id: String { bookmarkFileURL.path }

    /// Menu label. "Chrome" alone when there's nothing to disambiguate —
    /// "Chrome — Default" reads like a warning, not a name.
    var displayLabel: String {
        if kind == .safari { return "Safari" }
        return profileName == "Default" ? kind.displayName
                                        : "\(kind.displayName) — \(profileName)"
    }
}

enum BrowserImportError: Error, CustomStringConvertible {
    case needsFullDiskAccess
    case badFormat(String)
    var description: String {
        switch self {
        case .needsFullDiskAccess:
            return "Safari bookmarks are protected by macOS. Grant BookmarkBizarre "
                 + "Full Disk Access (System Settings → Privacy & Security → "
                 + "Full Disk Access), then try again."
        case .badFormat(let why):
            return "unrecognized bookmark data: \(why)"
        }
    }
}

// MARK: - Detection + import

enum BrowserImporter {

    /// Scan the standard on-disk locations for every profile that actually
    /// has a bookmark file. Pure filesystem — nothing is parsed or opened
    /// here except the Safari readability probe.
    static func detectProfiles() -> [BrowserProfile] {
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        var out: [BrowserProfile] = []

        // Chromium family: <base>/{Default,Profile N}/Bookmarks
        let chromiumBases: [(BrowserKind, String)] = [
            (.chrome, "Google/Chrome"),
            (.edge,   "Microsoft Edge"),
            (.brave,  "BraveSoftware/Brave-Browser"),
        ]
        for (kind, rel) in chromiumBases {
            let base = appSupport.appendingPathComponent(rel)
            let subdirs = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for dir in subdirs
            where dir.lastPathComponent == "Default" || dir.lastPathComponent.hasPrefix("Profile ") {
                let f = dir.appendingPathComponent("Bookmarks")
                guard fm.fileExists(atPath: f.path) else { continue }
                out.append(BrowserProfile(kind: kind, profileName: dir.lastPathComponent,
                                          bookmarkFileURL: f,
                                          readable: fm.isReadableFile(atPath: f.path)))
            }
        }

        // Firefox: Profiles/<salt>.<name>/places.sqlite. The salt prefix is
        // random per install — identity is the part after the first dot.
        let ffRoot = appSupport.appendingPathComponent("Firefox/Profiles")
        let ffDirs = (try? fm.contentsOfDirectory(at: ffRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in ffDirs.sorted(by: { $0.path < $1.path }) {
            let f = dir.appendingPathComponent("places.sqlite")
            guard fm.fileExists(atPath: f.path) else { continue }
            let raw = dir.lastPathComponent
            let parts = raw.split(separator: ".", maxSplits: 1)
            let name = parts.count == 2 ? String(parts[1]) : raw
            out.append(BrowserProfile(kind: .firefox, profileName: name,
                                      bookmarkFileURL: f,
                                      readable: fm.isReadableFile(atPath: f.path)))
        }

        // Safari: listed unconditionally — every Mac has it, and under a TCC
        // denial even fileExists() lies (returns false), so absence of the
        // file is indistinguishable from absence of permission. The open
        // probe is the only honest signal.
        let sf = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
        let probe = FileHandle(forReadingAtPath: sf.path)
        try? probe?.close()
        out.append(BrowserProfile(kind: .safari, profileName: "Safari",
                                  bookmarkFileURL: sf, readable: probe != nil))
        return out
    }

    /// Parse the profile's bookmark store and feed it through the shared
    /// import pipeline. The sha256 is over the exact bytes parsed, so the
    /// existing alreadyImported dedupe works unchanged — pulling the same
    /// unmodified browser data twice surfaces the existing library.
    static func importProfile(_ p: BrowserProfile, into directory: URL) throws -> LibraryInfo {
        let parsed: ParseResult
        let data: Data
        switch p.kind {
        case .chrome, .edge, .brave:
            data = try readOrExplain(p)
            parsed = try ChromiumBookmarks.parse(data)
        case .safari:
            data = try readOrExplain(p)
            parsed = try SafariBookmarks.parse(data)
        case .firefox:
            let snap = try FirefoxPlaces.snapshot(of: p.bookmarkFileURL)
            defer { try? FileManager.default.removeItem(at: snap.dir) }
            data = try Data(contentsOf: snap.db)
            parsed = try FirefoxPlaces.parse(at: snap.db)
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try Importer.importParsed(parsed,
            sourceName: p.displayLabel,
            sourcePath: p.bookmarkFileURL.path,
            sourceSHA256: sha,
            sourceBytes: data.count,
            into: directory,
            extraMeta: ["source_kind": p.kind.rawValue,
                        "source_profile": p.profileName])
    }

    private static func readOrExplain(_ p: BrowserProfile) throws -> Data {
        do { return try Data(contentsOf: p.bookmarkFileURL) }
        catch {
            // Safari's failure here is almost never "file missing" — it is
            // TCC saying no. Name the fix, not the errno.
            if p.kind == .safari { throw BrowserImportError.needsFullDiskAccess }
            throw ImportError.unreadable(error.localizedDescription)
        }
    }
}

// MARK: - Shared collector

/// All three vendor parsers walk a tree of nodes; this keeps the folder-id /
/// depth / position bookkeeping in ONE place instead of three slightly
/// different ones. URL decomposition and the VPN heuristic run here so a
/// browser pull gets the exact same treatment as a Netscape file line.
struct ParseCollector {
    private(set) var result = ParseResult()
    private var nextFolderID = 1
    private var position = 0

    mutating func folder(name: String, parentID: Int?, depth: Int,
                         addDate: Int? = nil, lastModified: Int? = nil,
                         isToolbar: Bool = false) -> Int {
        let id = nextFolderID
        nextFolderID += 1
        result.folders.append(ParsedFolder(
            id: id, parentID: parentID, name: name, depth: depth,
            addDate: addDate, lastModified: lastModified, isToolbar: isToolbar))
        return id
    }

    mutating func bookmark(title: String, url: String, folderID: Int?,
                           addDate: Int?, lastModified: Int? = nil) {
        let parts = URLParts(of: url)
        result.bookmarks.append(ParsedBookmark(
            folderID: folderID, position: position, title: title, url: url,
            scheme: parts.scheme, host: parts.host, path: parts.path,
            query: parts.query, fragment: parts.fragment,
            normURL: parts.normalized,
            addDate: addDate, lastModified: lastModified,
            iconURI: nil, tags: nil,
            requiresVPN: VPNHeuristic.requiresVPN(host: parts.host)))
        position += 1
    }

    /// A node we didn't understand — counted, never guessed at, same policy
    /// as the Netscape parser's skippedLines.
    mutating func skip() { result.skippedLines += 1 }
}

// MARK: - Chrome / Edge / Brave

enum ChromiumBookmarks {

    static func parse(_ data: Data) throws -> ParseResult {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = top["roots"] as? [String: Any] else {
            throw BrowserImportError.badFormat("no roots object — not a Chromium Bookmarks file")
        }
        var c = ParseCollector()
        // Fixed walk order → stable positions across pulls of unchanged data.
        // "synced" is what desktop Chrome calls the mobile bookmarks root.
        let named: [(key: String, title: String, toolbar: Bool)] = [
            ("bookmark_bar", "Bookmarks Bar", true),
            ("other",        "Other Bookmarks", false),
            ("synced",       "Mobile Bookmarks", false),
        ]
        for r in named {
            guard let node = roots[r.key] as? [String: Any] else { continue }
            let kids = node["children"] as? [[String: Any]] ?? []
            if kids.isEmpty { continue }   // an empty root is noise, not a folder
            let id = c.folder(name: r.title, parentID: nil, depth: 1,
                              addDate: chromeDate(node["date_added"]),
                              lastModified: chromeDate(node["date_modified"]),
                              isToolbar: r.toolbar)
            walk(kids, parentID: id, depth: 2, into: &c)
        }
        return c.result
    }

    private static func walk(_ nodes: [[String: Any]], parentID: Int, depth: Int,
                             into c: inout ParseCollector) {
        for node in nodes {
            switch node["type"] as? String {
            case "folder":
                let id = c.folder(name: node["name"] as? String ?? "",
                                  parentID: parentID, depth: depth,
                                  addDate: chromeDate(node["date_added"]),
                                  lastModified: chromeDate(node["date_modified"]))
                walk(node["children"] as? [[String: Any]] ?? [],
                     parentID: id, depth: depth + 1, into: &c)
            case "url":
                guard let url = node["url"] as? String, !url.isEmpty else {
                    c.skip(); continue
                }
                c.bookmark(title: node["name"] as? String ?? "", url: url,
                           folderID: parentID, addDate: chromeDate(node["date_added"]))
            default:
                c.skip()   // future node types: count them, don't guess
            }
        }
    }

    /// Chromium timestamps are STRINGS of microseconds since 1601-01-01
    /// (the Windows FILETIME epoch) — not unix, not milliseconds. 11644473600
    /// is the seconds between the 1601 and 1970 epochs. Firefox, same unit,
    /// DIFFERENT epoch — see FirefoxPlaces below; mixing them up dates every
    /// bookmark to the year 2395.
    static func chromeDate(_ v: Any?) -> Int? {
        guard let s = v as? String, let us = Int64(s), us > 0 else { return nil }
        let unix = us / 1_000_000 - 11_644_473_600
        return unix > 0 ? Int(unix) : nil
    }
}

// MARK: - Firefox

enum FirefoxPlaces {

    /// Firefox keeps places.sqlite open in WAL mode for its whole lifetime —
    /// reading the live file risks SQLITE_BUSY and, worse, a clean-looking
    /// read that silently misses the un-checkpointed -wal tail. Copy db+wal+shm
    /// together and read the copy; the caller deletes snap.dir when done.
    static func snapshot(of db: URL) throws -> (dir: URL, db: URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("bmz-firefox-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("places.sqlite")
        try fm.copyItem(at: db, to: dest)
        for ext in ["-wal", "-shm"] where fm.fileExists(atPath: db.path + ext) {
            try? fm.copyItem(at: URL(fileURLWithPath: db.path + ext),
                             to: URL(fileURLWithPath: dest.path + ext))
        }
        return (dir, dest)
    }

    private struct FFFolder { let id: Int; let parent: Int; let title: String
                              let guid: String; let added: Int?; let position: Int }
    private struct FFLink   { let parent: Int; let title: String; let url: String
                              let added: Int?; let position: Int }

    static func parse(at dbURL: URL) throws -> ParseResult {
        // READWRITE on purpose, no CREATE: this is our throwaway snapshot, and
        // sqlite may need write access to recover the copied WAL — a read-only
        // open of a db+wal pair can refuse to open at all.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw BrowserImportError.badFormat("cannot open places.sqlite snapshot")
        }
        defer { sqlite3_close(handle) }

        // moz_bookmarks.type: 1 = bookmark, 2 = folder. dateAdded is µs since
        // the UNIX epoch — same unit as Chrome, different epoch (see the
        // chromeDate comment). place: URLs are Firefox's internal smart
        // queries, not bookmarks.
        var folders: [FFFolder] = []
        let fs = try Stmt(handle, """
            SELECT id, parent, IFNULL(title,''), guid, dateAdded, position
            FROM moz_bookmarks WHERE type = 2
            """)
        while try fs.step() {
            folders.append(FFFolder(id: fs.colInt(0) ?? 0, parent: fs.colInt(1) ?? 0,
                                    title: fs.colText(2) ?? "", guid: fs.colText(3) ?? "",
                                    added: usToSeconds(fs.colInt(4)), position: fs.colInt(5) ?? 0))
        }
        var links: [FFLink] = []
        let bs = try Stmt(handle, """
            SELECT b.parent, IFNULL(b.title,''), p.url, b.dateAdded, b.position
            FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk
            WHERE b.type = 1 AND p.url NOT LIKE 'place:%'
            """)
        while try bs.step() {
            links.append(FFLink(parent: bs.colInt(0) ?? 0, title: bs.colText(1) ?? "",
                                url: bs.colText(2) ?? "", added: usToSeconds(bs.colInt(3)),
                                position: bs.colInt(4) ?? 0))
        }

        guard let root = folders.first(where: { $0.guid == "root________" }) else {
            throw BrowserImportError.badFormat("places.sqlite has no bookmark root")
        }
        let foldersByParent = Dictionary(grouping: folders, by: \.parent)
        let linksByParent = Dictionary(grouping: links, by: \.parent)

        // The root's children are Firefox's fixed top-level containers; their
        // titles in the DB are localization keys or blank, so name them by
        // guid. The tags root is folder-shaped but holds tag noise, not tree.
        let canonical: [String: String] = [
            "toolbar_____": "Bookmarks Toolbar",
            "menu________": "Bookmarks Menu",
            "unfiled_____": "Other Bookmarks",
            "mobile______": "Mobile Bookmarks",
        ]
        var c = ParseCollector()
        for top in (foldersByParent[root.id] ?? []).sorted(by: { $0.position < $1.position }) {
            if top.guid == "tags________" { continue }
            let name = canonical[top.guid] ?? (top.title.isEmpty ? top.guid : top.title)
            let hasContent = !(foldersByParent[top.id] ?? []).isEmpty
                          || !(linksByParent[top.id] ?? []).isEmpty
            if !hasContent { continue }
            let id = c.folder(name: name, parentID: nil, depth: 1, addDate: top.added,
                              isToolbar: top.guid == "toolbar_____")
            walk(ffID: top.id, ourID: id, depth: 2,
                 foldersByParent: foldersByParent, linksByParent: linksByParent, into: &c)
        }
        return c.result
    }

    /// DFS preserving Firefox's own sibling order: folders and links share
    /// one position sequence per parent, so they must be merged before
    /// sorting or folders all sink to the bottom.
    private static func walk(ffID: Int, ourID: Int, depth: Int,
                             foldersByParent: [Int: [FFFolder]],
                             linksByParent: [Int: [FFLink]],
                             into c: inout ParseCollector) {
        enum Child { case folder(FFFolder); case link(FFLink)
            var position: Int {
                switch self { case .folder(let f): return f.position
                              case .link(let l): return l.position }
            }
        }
        let children = ((foldersByParent[ffID] ?? []).map(Child.folder)
                      + (linksByParent[ffID] ?? []).map(Child.link))
            .sorted { $0.position < $1.position }
        for child in children {
            switch child {
            case .folder(let f):
                let id = c.folder(name: f.title, parentID: ourID, depth: depth, addDate: f.added)
                walk(ffID: f.id, ourID: id, depth: depth + 1,
                     foldersByParent: foldersByParent, linksByParent: linksByParent, into: &c)
            case .link(let l):
                if l.url.isEmpty { c.skip(); continue }
                c.bookmark(title: l.title, url: l.url, folderID: ourID, addDate: l.added)
            }
        }
    }

    /// µs since UNIX epoch → seconds. 0 / NULL = "Firefox didn't know".
    private static func usToSeconds(_ us: Int?) -> Int? {
        guard let us, us > 0 else { return nil }
        return us / 1_000_000
    }
}

// MARK: - Safari

enum SafariBookmarks {

    static func parse(_ data: Data) throws -> ParseResult {
        guard let top = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let children = top["Children"] as? [[String: Any]] else {
            throw BrowserImportError.badFormat("no Children array — not a Safari Bookmarks.plist")
        }
        var c = ParseCollector()
        walk(children, parentID: nil, depth: 1, into: &c)
        return c.result
    }

    /// Safari's top-level lists carry internal identifiers as their Titles;
    /// map them to what the Safari UI actually shows. Reading List IS
    /// bookmarks (URL + title), so it comes along as a folder.
    private static let rootTitles: [String: String] = [
        "BookmarksBar":          "Bookmarks Bar",
        "BookmarksMenu":         "Bookmarks Menu",
        "com.apple.ReadingList": "Reading List",
    ]

    private static func walk(_ nodes: [[String: Any]], parentID: Int?, depth: Int,
                             into c: inout ParseCollector) {
        for node in nodes {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeList":
                let raw = node["Title"] as? String ?? ""
                let kids = node["Children"] as? [[String: Any]] ?? []
                if kids.isEmpty { continue }
                let id = c.folder(name: rootTitles[raw] ?? raw, parentID: parentID,
                                  depth: depth, isToolbar: raw == "BookmarksBar")
                walk(kids, parentID: id, depth: depth + 1, into: &c)
            case "WebBookmarkTypeLeaf":
                guard let url = node["URLString"] as? String, !url.isEmpty else {
                    c.skip(); continue
                }
                // Titles hide one dictionary down; a leaf with no title at all
                // falls back to its URL, same as the browsers do on import.
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
                c.bookmark(title: title, url: url, folderID: parentID, addDate: nil)
            case "WebBookmarkTypeProxy":
                continue   // History et al. — structural nodes, not bookmarks
            default:
                c.skip()
            }
        }
    }
}
