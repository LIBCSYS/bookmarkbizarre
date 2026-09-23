import Foundation

// ============================================================================
// Models.swift — the shared contract between the data layer and the UI.
//
// This file is the single source of truth for what a "library" looks like.
// The data layer (NetscapeParser / SQLiteStore / Headless) implements the
// LibraryStore protocol and the two free functions declared at the bottom;
// the UI codes against the protocol only. Neither side edits the other's
// files — a mismatch gets fixed HERE first, then on both sides.
// ============================================================================

// MARK: - Library identity

/// One imported bookmark file = one SQLite database on disk. This is the
/// row the sidebar shows; everything heavier is read through LibraryStore.
struct LibraryInfo: Identifiable, Hashable {
    var id: String { fileURL.path }
    let fileURL: URL          // the .sqlite file
    let name: String          // display name — source file stem, not the DB filename
    let sourcePath: String    // where the .html came from, for provenance
    let bookmarkCount: Int
    let importedAt: Date?
}

// MARK: - Row types

/// A folder from the export's <H3> tree. `directCount` is bookmarks sitting
/// immediately inside — recursive totals are the UI's job if it wants them.
struct FolderRow: Identifiable, Hashable {
    let id: Int
    let parentID: Int?        // nil = top level of the file
    let name: String
    let depth: Int            // 1 = "Bookmarks Bar" tier
    let isToolbar: Bool
    let directCount: Int
}

/// A bookmark broken into its components. Mutable fields (`title`,
/// `markedForRemoval`, `requiresVPN`) are the ones the tile menu edits;
/// everything else is import-time fact and stays read-only.
struct BookmarkRow: Identifiable, Hashable {
    let id: Int
    var title: String
    let url: String
    let scheme: String?
    let host: String?
    let folderID: Int?        // nil = document root
    let position: Int         // original order in the file
    let addDate: Int?         // unix seconds as exported
    let dupGroup: Int?        // shared id when norm_url collides, else nil
    let iconURI: String?      // data: favicon Chrome embeds, verbatim
    var markedForRemoval: Bool
    var requiresVPN: Bool
}

// MARK: - Inventory

/// The evaluation pass over one library — computed live from SQL, never
/// cached, so it is always true to the current flags.
struct Inventory {
    var bookmarkCount = 0
    var folderCount = 0
    var uniqueHosts = 0
    var dupGroups = 0         // distinct norm_urls that collide
    var dupExtras = 0         // rows beyond the first in each group = deletable surplus
    var maxDepth = 0
    var untitled = 0          // empty titles
    var unparsedHosts = 0     // http(s) rows whose URL would not decompose
    var vpnCount = 0          // requires_vpn = 1
    var removalCount = 0      // marked_for_removal = 1
    var oldestAdd: Int?       // unix seconds, nil when the file carries no dates
    var newestAdd: Int?
    var schemes: [(name: String, count: Int)] = []   // descending by count
    var topHosts: [(name: String, count: Int)] = []  // top 15, descending
    var skippedLines = 0      // <DT> lines the parser refused to guess about
}

// MARK: - Store protocol (implemented by SQLiteStore.swift)

/// Handle to one library database. Cheap to open — the UI opens one per
/// selection and lets it die with the view. All methods throw on SQL error;
/// none return silently-wrong data.
protocol LibraryStore: AnyObject {
    var fileURL: URL { get }

    func inventory() throws -> Inventory
    func folders() throws -> [FolderRow]

    /// Filtered page of bookmarks. `search` matches title OR url OR host
    /// (LIKE, case-insensitive); empty string = no filter. `folderID` nil =
    /// whole file. Ordered by original file position.
    func bookmarks(search: String, folderID: Int?, limit: Int, offset: Int) throws -> [BookmarkRow]
    func bookmarkTotal(search: String, folderID: Int?) throws -> Int

    // Tile-menu edits — each is one UPDATE, no batching needed at this scale.
    func rename(bookmarkID: Int, to title: String) throws
    func setRemoval(bookmarkID: Int, _ flag: Bool) throws
    func setVPN(bookmarkID: Int, _ flag: Bool) throws

    // Collections: the "save this link into a new bookmark file" flow.
    // A collection is a named set of bookmark ids inside the same library DB;
    // export writes it back out as a NETSCAPE-Bookmark-file-1 .html that any
    // browser can re-import.
    func collections() throws -> [String]
    func addToCollection(bookmarkID: Int, name: String) throws
    func removeFromCollection(bookmarkID: Int, name: String) throws
    func collectionMembers(name: String) throws -> Set<Int>
    @discardableResult
    func exportCollection(name: String, to destination: URL) throws -> Int  // returns links written
}

// MARK: - Data-layer entry points (implemented in SQLiteStore.swift / Headless.swift)
//
//   func openLibrary(at url: URL) throws -> any LibraryStore
//
//   enum Importer {
//       /// Parses `source` (Netscape bookmark HTML), creates a NEW .sqlite in
//       /// `directory` named "<stem>__<sha8>.sqlite", fills it, and returns
//       /// its LibraryInfo. Re-importing the identical file (same sha) throws
//       /// ImportError.alreadyImported(existing:) rather than duplicating.
//       static func importFile(at source: URL, into directory: URL) throws -> LibraryInfo
//       /// Reads LibraryInfo back off an existing .sqlite (sidebar rescan).
//       static func info(for dbURL: URL) throws -> LibraryInfo
//   }
//
//   enum Headless {
//       /// `BookmarkBizarre --import <file.html> [--dir <dbdir>]` — runs the
//       /// full import, prints a one-line-per-fact inventory to stdout, exits.
//       /// Called first thing from the App init; returns immediately when the
//       /// process has no --import argument.
//       static func runIfNeeded()
//   }

// MARK: - VPN heuristic (import-time, data layer owns it)
//
// requires_vpn is seeded at import when the host pattern says "not reachable
// from the open internet": bare hostnames with no dot, *.local / *.internal /
// *.corp / *.lan suffixes, RFC1918 / loopback IP literals, and *.nyp.org
// (J's corporate estate — metadata only, the app never touches those hosts
// itself). The UI toggle overrides it per bookmark afterwards; a manual edit
// is never re-clobbered by re-inspection because import happens exactly once.

// MARK: - Shared constants

enum BMZ {
    /// Application Support/BookmarkBizarre/Libraries — every imported DB
    /// lives here; first launch finds it empty, which IS the blank slate.
    static var librariesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BookmarkBizarre/Libraries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Thumbnail PNG cache, keyed by sha256(norm_url).png — UI layer owns
    /// writes, but the path lives here so a future cleanup pass can find it.
    static var thumbnailDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BookmarkBizarre/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// UserDefaults key holding the path to the VPN client app. When set and
    /// a requires_vpn bookmark is opened, the client is launched first.
    static let vpnClientPathKey = "vpnClientPath"
}
