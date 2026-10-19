import SwiftUI

// ============================================================================
// LibraryManager — app-level state: which libraries exist, which is selected,
// and the one-line banner the UI uses instead of print()/alerts.
//
// Deliberately thin: it never opens a LibraryStore itself. Stores are opened
// per-selection by the detail view and die with it, so a half-written DB from
// a crashed import can never be pinned open by the sidebar.
// ============================================================================

@MainActor
final class LibraryManager: ObservableObject {

    /// Sidebar rows, newest import first. Empty on first launch — that empty
    /// array IS the blank slate; nothing is seeded, nothing auto-imports.
    @Published var libraries: [LibraryInfo] = []
    @Published var selectedID: LibraryInfo.ID?
    @Published var banner: Banner?

    /// `undo` turns a notice into "did X — Undo". Equality ignores the
    /// closure (closures aren't comparable) and keys on a per-banner id, so
    /// two identical texts in a row still count as two banners.
    struct Banner: Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
        var undo: (() -> Void)? = nil
        static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
    }

    /// Libraries parked by "Remove Library", for the restore menu.
    @Published var removed: [URL] = []

    init() {
        rescan()
        // Re-key existing thumbnail captures once (wave 2). Skipped under
        // XCTest: the test host must never rename J's real cache files.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            ThumbnailCacheMigration.runOnceIfNeeded(libraries: libraries.map(\.fileURL) + removed)
        }
    }

    var selected: LibraryInfo? {
        libraries.first { $0.id == selectedID }
    }

    /// Re-list the Libraries directory. Unreadable files are skipped, not
    /// fatal — .DS_Store and half-copied files land in every directory, and
    /// one bad file must not blank the whole sidebar.
    func rescan() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: BMZ.librariesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        libraries = urls
            .filter { $0.pathExtension == "sqlite" }
            .compactMap { try? Importer.info(for: $0) }
            .sorted { ($0.importedAt ?? .distantPast) > ($1.importedAt ?? .distantPast) }

        // A stale selection (library file deleted underneath us) falls back to
        // the newest library rather than leaving a dead detail pane.
        if let sel = selectedID, !libraries.contains(where: { $0.id == sel }) {
            selectedID = libraries.first?.id
        }
        removed = Importer.removedLibraries()
    }

    // MARK: - Remove / restore

    /// "Remove Library" (after the sidebar's confirmation). Moves the DB to
    /// Libraries/Removed — the original bookmark file is never touched and
    /// nothing is deleted. Undo rides on the banner; after that the restore
    /// menu still has it.
    func removeLibrary(_ lib: LibraryInfo) {
        do {
            let parked = try Importer.remove(dbURL: lib.fileURL)
            rescan()
            banner = Banner(text: "Removed \(lib.name) from the sidebar — file kept in Libraries/Removed",
                            isError: false,
                            undo: { [weak self] in self?.restoreLibrary(parked) })
        } catch {
            fail("Remove failed: \(error.localizedDescription)")
        }
    }

    func restoreLibrary(_ parked: URL) {
        do {
            let info = try Importer.restore(removedURL: parked, into: BMZ.librariesDirectory)
            rescan()
            selectedID = info.id
            notice("Restored \(info.name)")
        } catch ImportError.alreadyImported(let existing) {
            rescan()
            selectedID = existing.id
            fail("\(existing.name) was re-imported since it was removed — kept the current copy, parked one is still in Libraries/Removed")
        } catch {
            fail("Restore failed: \(error.localizedDescription)")
        }
    }

    /// Full import flow for one picked file. Re-picking a file already in the
    /// library is a selection, not an error — the data layer detects it by
    /// content hash and we just jump to the existing row.
    func importFile(_ url: URL) {
        // No-op outside the sandbox, mandatory inside it. Taking the scope
        // unconditionally means flipping the sandbox on later costs nothing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let info = try Importer.importFile(at: url, into: BMZ.librariesDirectory)
            rescan()
            selectedID = info.id
            notice("Imported \(info.name) — \(info.bookmarkCount) bookmarks")
        } catch ImportError.alreadyImported(let existing) {
            rescan()
            selectedID = existing.id
            notice("\(existing.name) is already in the library — selected it")
        } catch {
            fail("Import failed: \(error.localizedDescription)")
        }
    }

    /// Direct pull from an installed browser profile. Same landing path as a
    /// picked file — content-hash dedupe included, so re-pulling an unchanged
    /// profile selects the existing row instead of stacking copies.
    func importBrowser(_ profile: BrowserProfile) {
        do {
            let info = try BrowserImporter.importProfile(profile, into: BMZ.librariesDirectory)
            rescan()
            selectedID = info.id
            notice("Pulled \(profile.displayLabel) — \(info.bookmarkCount) bookmarks")
        } catch ImportError.alreadyImported(let existing) {
            rescan()
            selectedID = existing.id
            notice("\(profile.displayLabel) is unchanged since its last pull — selected it")
        } catch {
            // Safari's TCC denial lands here with the Full Disk Access
            // instructions the data layer wrote; surface it verbatim.
            fail("Browser pull failed: \(error.localizedDescription)")
        }
    }

    func notice(_ text: String) { banner = Banner(text: text, isError: false) }
    func undoable(_ text: String, undo: @escaping () -> Void) {
        banner = Banner(text: text, isError: false, undo: undo)
    }
    func fail(_ text: String)   { banner = Banner(text: text, isError: true) }
}
