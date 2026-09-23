import Foundation
import SQLite3
import CryptoKit

// ============================================================================
// SQLiteStore.swift — one imported bookmark file = one SQLite database.
// Raw sqlite3 C API on purpose: no package dependency, and the schema is
// small enough that a wrapper library would cost more than it saves.
// ============================================================================

// sqlite3_bind_text's last argument tells sqlite who owns the buffer.
// Swift bridges String to a TEMPORARY C string that dies when the call
// returns — pass SQLITE_STATIC and sqlite reads freed memory at step time.
// SQLITE_TRANSIENT forces an immediate copy. Non-negotiable.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum ImportError: Error, CustomStringConvertible {
    case alreadyImported(existing: LibraryInfo)
    case unreadable(String)
    var description: String {
        switch self {
        case .alreadyImported(let e): return "already imported as \(e.fileURL.lastPathComponent)"
        case .unreadable(let why): return "cannot read source file: \(why)"
        }
    }
}

// MARK: - Statement wrapper

/// Owns one prepared statement; finalize rides on deinit so early throws
/// can't leak handles (a leaked statement keeps the whole DB locked).
final class Stmt {   // internal for BrowserImport (read-only sweep of the places.sqlite snapshot)
    let ptr: OpaquePointer
    private let db: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else {
            throw SQLError(message: "prepare: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
        }
        self.ptr = p
        self.db = db
    }
    deinit { sqlite3_finalize(ptr) }

    /// Binds are 1-indexed in sqlite; the array is 0-indexed here. Ints go
    /// through int64 — sqlite3_bind_int truncates on 64-bit ids.
    func bind(_ values: [SQLValue]) throws {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .null:        rc = sqlite3_bind_null(ptr, idx)
            case .int(let n):  rc = sqlite3_bind_int64(ptr, idx, Int64(n))
            case .text(let s): rc = sqlite3_bind_text(ptr, idx, s, -1, SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else {
                throw SQLError(message: "bind \(idx): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// True while rows remain; throws on anything that isn't ROW or DONE.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(ptr) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLError(message: "step: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func reset() { sqlite3_reset(ptr); sqlite3_clear_bindings(ptr) }

    func colInt(_ i: Int32) -> Int? {
        sqlite3_column_type(ptr, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(ptr, i))
    }
    func colText(_ i: Int32) -> String? {
        sqlite3_column_text(ptr, i).map { String(cString: $0) }
    }
}

enum SQLValue {
    case null
    case int(Int)
    case text(String)
    // Optionals collapse to .null so insert loops don't branch per column
    static func of(_ v: Int?) -> SQLValue { v.map { .int($0) } ?? .null }
    static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    static func of(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
}

// MARK: - Library database

func openLibrary(at url: URL) throws -> any LibraryStore {
    try LibraryDB(at: url, create: false)
}

final class LibraryDB: LibraryStore {
    let fileURL: URL
    private var db: OpaquePointer?

    /// READWRITE without CREATE for normal opens — a typo'd path must error,
    /// not conjure an empty database that then "has no bookmarks".
    init(at url: URL, create: Bool) throws {
        fileURL = url
        let flags = create
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLError(message: "\(msg): \(url.path)")
        }
        db = handle
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(db) }

    // MARK: plumbing

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLError(message: "\(msg) — \(sql.prefix(120))")
        }
    }

    private func run(_ sql: String, _ binds: [SQLValue] = []) throws {
        let s = try Stmt(db!, sql)
        try s.bind(binds)
        try s.step()
    }

    private func scalarInt(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        let s = try Stmt(db!, sql)
        try s.bind(binds)
        return try s.step() ? (s.colInt(0) ?? 0) : 0
    }

    private func optScalarInt(_ sql: String) throws -> Int? {
        let s = try Stmt(db!, sql)
        return try s.step() ? s.colInt(0) : nil
    }

    private func pairRows(_ sql: String) throws -> [(name: String, count: Int)] {
        let s = try Stmt(db!, sql)
        var out: [(String, Int)] = []
        while try s.step() {
            out.append((s.colText(0) ?? "(none)", s.colInt(1) ?? 0))
        }
        return out
    }

    // MARK: schema

    fileprivate func createSchema() throws {
        try exec("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE folders(
                id INTEGER PRIMARY KEY,
                parent_id INTEGER REFERENCES folders(id),
                name TEXT NOT NULL,
                depth INTEGER NOT NULL,
                add_date INTEGER,
                last_modified INTEGER,
                is_toolbar INTEGER DEFAULT 0);
            CREATE TABLE bookmarks(
                id INTEGER PRIMARY KEY,
                folder_id INTEGER REFERENCES folders(id),
                position INTEGER,
                title TEXT,
                url TEXT NOT NULL,
                scheme TEXT, host TEXT, path TEXT, query TEXT, fragment TEXT,
                norm_url TEXT,
                dup_group INTEGER,
                add_date INTEGER, last_modified INTEGER,
                icon_uri TEXT, tags TEXT,
                marked_for_removal INTEGER DEFAULT 0,
                requires_vpn INTEGER DEFAULT 0);
            CREATE TABLE collections(
                name TEXT NOT NULL,
                bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id),
                PRIMARY KEY(name, bookmark_id));
            CREATE INDEX ix_bm_host ON bookmarks(host);
            CREATE INDEX ix_bm_norm ON bookmarks(norm_url);
            CREATE INDEX ix_bm_folder ON bookmarks(folder_id);
            """)
    }

    fileprivate func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)",
                [.text(key), .text(value)])
    }

    fileprivate func meta(_ key: String) throws -> String? {
        let s = try Stmt(db!, "SELECT value FROM meta WHERE key = ?")
        try s.bind([.text(key)])
        return try s.step() ? s.colText(0) : nil
    }

    // MARK: import fill (called by Importer inside one transaction)

    fileprivate func fill(from parsed: ParseResult) throws {
        try exec("BEGIN")
        do {
            let fs = try Stmt(db!, """
                INSERT INTO folders(id, parent_id, name, depth, add_date, last_modified, is_toolbar)
                VALUES(?,?,?,?,?,?,?)
                """)
            for f in parsed.folders {
                try fs.bind([.int(f.id), .of(f.parentID), .text(f.name), .int(f.depth),
                             .of(f.addDate), .of(f.lastModified), .of(f.isToolbar)])
                try fs.step()
                fs.reset()
            }
            let bs = try Stmt(db!, """
                INSERT INTO bookmarks(folder_id, position, title, url, scheme, host, path,
                    query, fragment, norm_url, add_date, last_modified, icon_uri, tags, requires_vpn)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            for b in parsed.bookmarks {
                try bs.bind([.of(b.folderID), .int(b.position), .text(b.title), .text(b.url),
                             .of(b.scheme), .of(b.host), .of(b.path), .of(b.query), .of(b.fragment),
                             .text(b.normURL), .of(b.addDate), .of(b.lastModified),
                             .of(b.iconURI), .of(b.tags), .of(b.requiresVPN)])
                try bs.step()
                bs.reset()
            }
            // Dup pass after the fact: MIN(id) per colliding norm_url becomes the
            // group id, singletons stay NULL so "has a dup" is a NOT NULL test.
            try exec("""
                UPDATE bookmarks SET dup_group =
                    (SELECT MIN(b2.id) FROM bookmarks b2 WHERE b2.norm_url = bookmarks.norm_url)
                WHERE norm_url IN
                    (SELECT norm_url FROM bookmarks GROUP BY norm_url HAVING COUNT(*) > 1)
                """)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - LibraryStore: reads

    func inventory() throws -> Inventory {
        var inv = Inventory()
        inv.bookmarkCount = try scalarInt("SELECT COUNT(*) FROM bookmarks")
        inv.folderCount = try scalarInt("SELECT COUNT(*) FROM folders")
        inv.uniqueHosts = try scalarInt("SELECT COUNT(DISTINCT host) FROM bookmarks WHERE host IS NOT NULL")
        inv.dupGroups = try scalarInt("""
            SELECT COUNT(*) FROM
                (SELECT 1 FROM bookmarks GROUP BY norm_url HAVING COUNT(*) > 1)
            """)
        inv.dupExtras = try scalarInt("""
            SELECT IFNULL(SUM(c - 1), 0) FROM
                (SELECT COUNT(*) AS c FROM bookmarks GROUP BY norm_url HAVING c > 1)
            """)
        inv.maxDepth = try scalarInt("SELECT IFNULL(MAX(depth), 0) FROM folders")
        inv.untitled = try scalarInt("SELECT COUNT(*) FROM bookmarks WHERE title = ''")
        inv.unparsedHosts = try scalarInt("""
            SELECT COUNT(*) FROM bookmarks
            WHERE scheme IN ('http','https') AND host IS NULL
            """)
        inv.vpnCount = try scalarInt("SELECT COUNT(*) FROM bookmarks WHERE requires_vpn = 1")
        inv.removalCount = try scalarInt("SELECT COUNT(*) FROM bookmarks WHERE marked_for_removal = 1")
        // add_date 0 means "the browser didn't know" — excluded so the oldest
        // bookmark isn't reported as 1970
        inv.oldestAdd = try optScalarInt("SELECT MIN(add_date) FROM bookmarks WHERE add_date > 0")
        inv.newestAdd = try optScalarInt("SELECT MAX(add_date) FROM bookmarks WHERE add_date > 0")
        inv.schemes = try pairRows("""
            SELECT IFNULL(scheme, '(none)'), COUNT(*) FROM bookmarks
            GROUP BY 1 ORDER BY 2 DESC
            """)
        inv.topHosts = try pairRows("""
            SELECT host, COUNT(*) FROM bookmarks WHERE host IS NOT NULL
            GROUP BY host ORDER BY 2 DESC, host LIMIT 15
            """)
        inv.skippedLines = Int(try meta("skipped_lines") ?? "0") ?? 0
        return inv
    }

    func folders() throws -> [FolderRow] {
        let s = try Stmt(db!, """
            SELECT f.id, f.parent_id, f.name, f.depth, f.is_toolbar,
                   (SELECT COUNT(*) FROM bookmarks b WHERE b.folder_id = f.id)
            FROM folders f ORDER BY f.id
            """)
        var out: [FolderRow] = []
        while try s.step() {
            out.append(FolderRow(
                id: s.colInt(0) ?? 0,
                parentID: s.colInt(1),
                name: s.colText(2) ?? "",
                depth: s.colInt(3) ?? 0,
                isToolbar: (s.colInt(4) ?? 0) == 1,
                directCount: s.colInt(5) ?? 0))
        }
        return out
    }

    /// WHERE assembled once, shared with bookmarkTotal, so the page and its
    /// count can never disagree about what "filtered" means.
    private func filterClause(search: String, folderID: Int?) -> (sql: String, binds: [SQLValue]) {
        var conds: [String] = []
        var binds: [SQLValue] = []
        if !search.isEmpty {
            conds.append("(title LIKE ? OR url LIKE ? OR host LIKE ?)")
            let pattern = "%\(search)%"
            binds += [.text(pattern), .text(pattern), .text(pattern)]
        }
        if let folderID {
            conds.append("folder_id = ?")
            binds.append(.int(folderID))
        }
        return (conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND "), binds)
    }

    func bookmarks(search: String, folderID: Int?, limit: Int, offset: Int) throws -> [BookmarkRow] {
        let f = filterClause(search: search, folderID: folderID)
        let s = try Stmt(db!, """
            SELECT id, title, url, scheme, host, folder_id, position, add_date,
                   dup_group, icon_uri, marked_for_removal, requires_vpn
            FROM bookmarks\(f.sql) ORDER BY position LIMIT ? OFFSET ?
            """)
        try s.bind(f.binds + [.int(limit), .int(offset)])
        var out: [BookmarkRow] = []
        while try s.step() {
            out.append(BookmarkRow(
                id: s.colInt(0) ?? 0,
                title: s.colText(1) ?? "",
                url: s.colText(2) ?? "",
                scheme: s.colText(3),
                host: s.colText(4),
                folderID: s.colInt(5),
                position: s.colInt(6) ?? 0,
                addDate: s.colInt(7),
                dupGroup: s.colInt(8),
                iconURI: s.colText(9),
                markedForRemoval: (s.colInt(10) ?? 0) == 1,
                requiresVPN: (s.colInt(11) ?? 0) == 1))
        }
        return out
    }

    func bookmarkTotal(search: String, folderID: Int?) throws -> Int {
        let f = filterClause(search: search, folderID: folderID)
        return try scalarInt("SELECT COUNT(*) FROM bookmarks\(f.sql)", f.binds)
    }

    // MARK: - LibraryStore: edits

    func rename(bookmarkID: Int, to title: String) throws {
        try run("UPDATE bookmarks SET title = ? WHERE id = ?", [.text(title), .int(bookmarkID)])
    }

    func setRemoval(bookmarkID: Int, _ flag: Bool) throws {
        try run("UPDATE bookmarks SET marked_for_removal = ? WHERE id = ?", [.of(flag), .int(bookmarkID)])
    }

    func setVPN(bookmarkID: Int, _ flag: Bool) throws {
        try run("UPDATE bookmarks SET requires_vpn = ? WHERE id = ?", [.of(flag), .int(bookmarkID)])
    }

    // MARK: - LibraryStore: collections

    func collections() throws -> [String] {
        let s = try Stmt(db!, "SELECT DISTINCT name FROM collections ORDER BY name")
        var out: [String] = []
        while try s.step() { out.append(s.colText(0) ?? "") }
        return out
    }

    func addToCollection(bookmarkID: Int, name: String) throws {
        // OR IGNORE: adding the same link twice is a no-op, not an error —
        // the tile menu shouldn't punish an enthusiastic double click
        try run("INSERT OR IGNORE INTO collections(name, bookmark_id) VALUES(?, ?)",
                [.text(name), .int(bookmarkID)])
    }

    func removeFromCollection(bookmarkID: Int, name: String) throws {
        try run("DELETE FROM collections WHERE name = ? AND bookmark_id = ?",
                [.text(name), .int(bookmarkID)])
    }

    func collectionMembers(name: String) throws -> Set<Int> {
        let s = try Stmt(db!, "SELECT bookmark_id FROM collections WHERE name = ?")
        try s.bind([.text(name)])
        var out: Set<Int> = []
        while try s.step() { if let id = s.colInt(0) { out.insert(id) } }
        return out
    }

    @discardableResult
    func exportCollection(name: String, to destination: URL) throws -> Int {
        let s = try Stmt(db!, """
            SELECT b.title, b.url, b.add_date FROM bookmarks b
            JOIN collections c ON c.bookmark_id = b.id
            WHERE c.name = ? ORDER BY b.position
            """)
        try s.bind([.text(name)])

        // The header lines browsers key on when re-importing — the DOCTYPE
        // especially; Safari refuses the file without it.
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3>\(Self.escape(name))</H3>
            <DL><p>

        """
        var count = 0
        while try s.step() {
            let title = Self.escape(s.colText(0) ?? "")
            let href = Self.escape(s.colText(1) ?? "")
            let add = s.colInt(2).map { " ADD_DATE=\"\($0)\"" } ?? ""
            out += "        <DT><A HREF=\"\(href)\"\(add)>\(title)</A>\n"
            count += 1
        }
        out += "    </DL><p>\n</DL><p>\n"
        try out.write(to: destination, atomically: true, encoding: .utf8)
        return count
    }

    /// Escape for both attribute values and element text. & first or the
    /// escapes escape each other.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Importer

enum Importer {

    /// Parse source → new "<stem>__<sha8>.sqlite" in directory. The sha8 in
    /// the filename is both dedupe and provenance: the same file re-imported
    /// lands on the same name, and a renamed copy is still caught by the
    /// directory scan below.
    static func importFile(at source: URL, into directory: URL) throws -> LibraryInfo {
        let data: Data
        do { data = try Data(contentsOf: source) }
        catch { throw ImportError.unreadable(error.localizedDescription) }

        // Latin-1 fallback: pre-UTF8 exports exist and Latin-1 decodes any
        // byte sequence, so this path can't fail — it can only mangle high-bit
        // characters, which beats refusing the whole file.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable("not decodable as UTF-8 or Latin-1")
        }

        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try importParsed(NetscapeParser.parse(text),
                                sourceName: source.lastPathComponent,
                                sourcePath: source.path,
                                sourceSHA256: sha,
                                sourceBytes: data.count,
                                into: directory,
                                extraMeta: ["source_kind": "file"])
    }

    /// Shared back half of every import: content-hash dedupe, DB creation,
    /// fill, provenance stamping. importFile feeds it Netscape HTML;
    /// BrowserImport.swift feeds it Chrome/Firefox/Safari trees. Everything
    /// downstream (dup pass, inventory, UI) cannot tell the difference —
    /// which is the point.  // internal for BrowserImport
    static func importParsed(_ parsed: ParseResult,
                             sourceName: String,
                             sourcePath: String,
                             sourceSHA256: String,
                             sourceBytes: Int,
                             into directory: URL,
                             extraMeta: [String: String] = [:]) throws -> LibraryInfo {
        let sha8 = String(sourceSHA256.prefix(8))

        // Same content already imported under ANY name → surface the existing
        // library instead of silently making a twin.
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasSuffix("__\(sha8).sqlite") }
        if let existing {
            throw ImportError.alreadyImported(existing: try info(for: existing))
        }

        let stem = (sourceName as NSString).deletingPathExtension
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
        let dbURL = directory.appendingPathComponent("\(stem)__\(sha8).sqlite")

        let db = try LibraryDB(at: dbURL, create: true)
        do {
            try db.createSchema()
            try db.fill(from: parsed)
            let iso = ISO8601DateFormatter().string(from: Date())
            try db.setMeta("source_name", sourceName)
            try db.setMeta("source_path", sourcePath)
            try db.setMeta("source_sha256", sourceSHA256)
            try db.setMeta("source_bytes", String(sourceBytes))
            try db.setMeta("imported_at", iso)
            try db.setMeta("skipped_lines", String(parsed.skippedLines))
            try db.setMeta("app_version",
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            for (k, v) in extraMeta { try db.setMeta(k, v) }
        } catch {
            // Half-written DB is worse than no DB: the sidebar would list a
            // library that lies. This file is seconds old and app-created,
            // so removing it is cleanup, not deletion of J's data.
            try? FileManager.default.removeItem(at: dbURL)
            throw error
        }
        return try info(for: dbURL)
    }

    /// LibraryInfo straight off an existing DB — what the sidebar rescan uses.
    static func info(for dbURL: URL) throws -> LibraryInfo {
        let db = try LibraryDB(at: dbURL, create: false)
        let count = try db.bookmarkTotal(search: "", folderID: nil)
        let sourceName = try db.meta("source_name") ?? dbURL.lastPathComponent
        let sourcePath = try db.meta("source_path") ?? ""
        let importedAt = try db.meta("imported_at").flatMap { ISO8601DateFormatter().date(from: $0) }
        // Display name = the source file's stem — what J exported, not our
        // sha-suffixed storage name
        let name = (sourceName as NSString).deletingPathExtension
        return LibraryInfo(fileURL: dbURL, name: name.isEmpty ? sourceName : name,
                           sourcePath: sourcePath, bookmarkCount: count, importedAt: importedAt)
    }
}
