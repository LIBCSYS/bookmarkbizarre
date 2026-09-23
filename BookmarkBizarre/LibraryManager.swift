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

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    init() {
        rescan()
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
    func fail(_ text: String)   { banner = Banner(text: text, isError: true) }
}
