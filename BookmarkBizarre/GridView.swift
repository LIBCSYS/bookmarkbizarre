import SwiftUI
import AppKit

// ============================================================================
// GridView — J's "sheet of web pages": a borderless wall of page tiles.
// Hover enlarges a tile to readable size, click opens the default browser,
// and a slim strip on each tile's right edge carries the per-link actions.
// ============================================================================

struct GridView: View {
    let store: any LibraryStore
    let search: String
    /// Where J is standing in the folder tree. nil = the file's top level.
    /// A Binding so the toolbar picker and the in-grid drill-down move the
    /// same needle.
    @Binding var folderID: Int?
    let folderRows: [FolderRow]
    @EnvironmentObject private var manager: LibraryManager

    @State private var rows: [BookmarkRow] = []
    @State private var total = 0
    @State private var loading = false
    /// Only one tile may be enlarged; tracking the id here (not per-tile)
    /// lets the grid raise that tile's zIndex so it draws over its neighbors.
    @State private var hoveredID: Int?
    /// J's zoom dial: small = the whole section on one sheet, large = 3-5
    /// across. Persisted — the size he settles on is a preference, not
    /// per-session mood.
    @AppStorage("gridTileSize") private var tileSize = 200.0

    private let pageSize = 400

    /// Hover growth shrinks as tiles grow — 1.6× of an already-large tile
    /// would punch past the window edge; a small tile needs the full jump
    /// to reach "a good visible area".
    private var hoverScale: CGFloat {
        min(1.6, max(1.2, 340 / tileSize))
    }

    /// Dwell target: keep hovering and the tile keeps growing to reading
    /// size (J: "the longer we hover, the bigger it gets"). Aims for ~680pt
    /// of on-screen width whatever the slider says, capped so a tiny-tile
    /// sheet doesn't quadruple into absurdity.
    private var dwellScale: CGFloat {
        min(4.0, max(hoverScale + 0.4, 680 / tileSize))
    }

    // Explorer semantics: the tree on the left navigates, the portal only
    // ever shows pages. A folder selection covers its whole subtree; the
    // root covers the whole file — lazily paged, so "all the thumbnails"
    // materialize as J scrolls rather than in one 6,600-tile stampede.
    private var searching: Bool { !search.isEmpty }
    private var scope: FolderScope {
        if searching { return .all }
        if let folderID { return .folder(folderID) }
        return .all
    }

    private var folderByID: [Int: FolderRow] {
        Dictionary(uniqueKeysWithValues: folderRows.map { ($0.id, $0) })
    }
    /// Root → current chain for the breadcrumb, walked via parentID.
    private var breadcrumb: [FolderRow] {
        var chain: [FolderRow] = []
        var cursor = folderID
        while let id = cursor, let row = folderByID[id] {
            chain.append(row)
            cursor = row.parentID
        }
        return chain.reversed()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.3),
                                       spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(rows) { row in
                        BookmarkTile(
                            row: row,
                            store: store,
                            hoverScale: hoverScale,
                            dwellScale: dwellScale,
                            isHovered: hoveredID == row.id,
                            onHover: { inside in
                                if inside {
                                    hoveredID = row.id
                                } else if hoveredID == row.id {
                                    hoveredID = nil
                                }
                            },
                            onChanged: { apply($0) },
                            onNotice: { manager.notice($0) },
                            onError: { manager.fail($0) }
                        )
                        .zIndex(hoveredID == row.id ? 10 : 0)
                        .onAppear {
                            // Infinite scroll: the last materialized tile asks for
                            // the next page. LazyVGrid only builds visible cells,
                            // so this fires exactly at the frontier.
                            if row.id == rows.last?.id { loadMore() }
                        }
                    }
                }

                if !searching && rows.isEmpty {
                    Text("Nothing under this folder")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(40)
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task(id: "\(search)|\(folderID.map(String.init) ?? "top")") {
            // Debounce: typing "github" is 6 keystrokes, not 6 SQL sweeps.
            // Folder switches ride the same 250ms — imperceptible on a click.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    /// Breadcrumb while browsing; a plain banner while searching, because
    /// search results come from everywhere and a folder trail would lie.
    @ViewBuilder
    private var header: some View {
        if searching {
            Label("Search results — whole file", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                crumb(name: "Library", symbol: "house.fill") { folderID = nil }
                ForEach(breadcrumb) { f in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    crumb(name: f.name.isEmpty ? "(untitled)" : f.name,
                          symbol: nil,
                          isCurrent: f.id == folderID) { folderID = f.id }
                }
            }
            .lineLimit(1)
        }
    }

    private func crumb(name: String, symbol: String?, isCurrent: Bool = false,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(name)
            }
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    /// Count readout + the size dial, one thin bar under the sheet.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if loading { ProgressView().controlSize(.small) }
            Text(countLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "square.grid.4x3.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $tileSize, in: 90...340)
                .frame(width: 160)
                .controlSize(.small)
                .help("Tile size — small shows everything, large shows a few across")
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countLine: String {
        if searching {
            return total == 0 ? "No bookmarks match" : "\(total) matches across the file"
        }
        guard total > 0 else { return "Nothing under this folder" }
        return rows.count < total ? "showing \(rows.count) of \(total) pages" : "\(total) pages"
    }

    // MARK: - Data

    private func reload() {
        // The folder that just lost focus stops rendering NOW — otherwise its
        // leftover captures hold the three slots and the new folder's tiles
        // queue behind ghosts.
        ThumbnailProvider.shared.flushPending()
        do {
            total = try store.bookmarkTotal(search: search, scope: scope)
            rows = try store.bookmarks(search: search, scope: scope, limit: pageSize, offset: 0)
        } catch {
            manager.fail("Load failed: \(error.localizedDescription)")
        }
    }

    private func loadMore() {
        guard rows.count < total, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try store.bookmarks(search: search, scope: scope, limit: pageSize, offset: rows.count)
            rows.append(contentsOf: next)
        } catch {
            manager.fail("Load failed: \(error.localizedDescription)")
        }
    }

    /// A tile edited itself (rename/flag) — patch the row in place instead of
    /// re-querying 6,000 rows for a one-field change.
    private func apply(_ updated: BookmarkRow) {
        if let i = rows.firstIndex(where: { $0.id == updated.id }) {
            rows[i] = updated
        }
    }
}

// MARK: - Tile

struct BookmarkTile: View {
    let row: BookmarkRow
    let store: any LibraryStore
    let hoverScale: CGFloat
    let dwellScale: CGFloat
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onChanged: (BookmarkRow) -> Void
    let onNotice: (String) -> Void
    let onError: (String) -> Void

    @AppStorage(BMZ.vpnClientPathKey) private var vpnClientPath = ""
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showCollect = false
    /// Current scale, animated in two stages: a quick pop to hoverScale, then
    /// a slow easeInOut crawl to dwellScale while the pointer stays put.
    @State private var zoom: CGFloat = 1
    @State private var dwellTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TileThumbnail(row: row)

            caption
            badges
            controlStrip
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        // Marked-for-removal reads as "going away" without hiding it — J
        // still needs to see it to change his mind.
        .opacity(row.markedForRemoval ? 0.35 : 1)
        .scaleEffect(zoom)
        .shadow(color: .black.opacity(zoom > 1 ? 0.35 : 0), radius: zoom > 1 ? 18 : 0, y: 4)
        .onChange(of: isHovered) { _, inside in
            dwellTask?.cancel()
            if inside {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { zoom = hoverScale }
                dwellTask = Task {
                    // Beat of stillness before the crawl starts, so sweeping
                    // the pointer across the sheet doesn't balloon every tile
                    // it crosses.
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 1.8)) { zoom = dwellScale }
                }
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { zoom = 1 }
            }
        }
        .onHover(perform: onHover)
        .onTapGesture(perform: open)
        .help(row.url)
    }

    // MARK: Pieces

    private var caption: some View {
        // Bottom gradient keeps white page snapshots from swallowing the title.
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title.isEmpty ? (row.host ?? row.url) : row.title)
                .font(.caption.weight(.medium))
                .strikethrough(row.markedForRemoval)
                .lineLimit(1)
                .foregroundStyle(.white)
            if let host = row.host {
                Text(host)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.75), .black.opacity(0)],
                startPoint: .bottom, endPoint: .top)
        )
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if row.requiresVPN {
                badge("lock.shield.fill", tint: .orange)
            }
            if row.markedForRemoval {
                badge("trash.fill", tint: .red)
            }
            if row.dupGroup != nil {
                badge("doc.on.doc.fill", tint: .blue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(tint.opacity(0.85), in: Circle())
    }

    /// The right-edge menu. Low-opacity, hover-only, vertical — "small and
    /// inconspicuous" per J, so it never competes with the page itself.
    private var controlStrip: some View {
        VStack(spacing: 6) {
            stripButton("pencil", help: "Rename") {
                renameText = row.title
                showRename = true
            }
            .popover(isPresented: $showRename, arrowEdge: .trailing) { renamePopover }

            stripButton(row.markedForRemoval ? "arrow.uturn.backward" : "trash",
                        help: row.markedForRemoval ? "Unmark removal" : "Mark for removal") {
                toggleRemoval()
            }

            stripButton(row.requiresVPN ? "lock.open" : "lock.shield",
                        help: row.requiresVPN ? "Clear VPN flag" : "Flag as VPN-required") {
                toggleVPN()
            }

            stripButton("plus.square.on.square", help: "Save to bookmark file…") {
                showCollect = true
            }
            .popover(isPresented: $showCollect, arrowEdge: .trailing) {
                CollectPopover(row: row, store: store, onNotice: onNotice, onError: onError)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(isHovered ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    private func stripButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename bookmark")
                .font(.headline)
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(saveRename)
            HStack {
                Spacer()
                Button("Save", action: saveRename)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    // MARK: Actions

    private func open() {
        guard let url = URL(string: row.url) else {
            onError("Not an openable URL: \(row.url)")
            return
        }
        if row.requiresVPN {
            if !vpnClientPath.isEmpty {
                // Fire the client first, give the tunnel a beat, then hand the
                // page to the default browser. 2s is not a connection guarantee
                // — it just wins the race often enough to be useful.
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: vpnClientPath),
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
                onNotice("Launching VPN client, then opening \(row.host ?? "page")…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                onNotice("VPN required — no client configured (gear icon, bottom of sidebar)")
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveRename() {
        showRename = false
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != row.title else { return }
        do {
            try store.rename(bookmarkID: row.id, to: trimmed)
            var r = row
            r.title = trimmed
            onChanged(r)
        } catch {
            onError("Rename failed: \(error.localizedDescription)")
        }
    }

    private func toggleRemoval() {
        do {
            try store.setRemoval(bookmarkID: row.id, !row.markedForRemoval)
            var r = row
            r.markedForRemoval.toggle()
            onChanged(r)
        } catch {
            onError("Flag failed: \(error.localizedDescription)")
        }
    }

    private func toggleVPN() {
        do {
            try store.setVPN(bookmarkID: row.id, !row.requiresVPN)
            var r = row
            r.requiresVPN.toggle()
            onChanged(r)
        } catch {
            onError("Flag failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Collection popover

/// "Save this link in a new bookmark file" — a collection is the staging
/// area, export writes the actual .html. Kept per-library (in the same DB)
/// so the file travels with the data it came from.
struct CollectPopover: View {
    let row: BookmarkRow
    let store: any LibraryStore
    let onNotice: (String) -> Void
    let onError: (String) -> Void

    @State private var names: [String] = []
    @State private var membership: Set<String> = []
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save to bookmark file")
                .font(.headline)

            if names.isEmpty {
                Text("No collections yet — name one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Button {
                            toggle(name)
                        } label: {
                            Label(name, systemImage: membership.contains(name) ? "checkmark.square.fill" : "square")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Export…") { exportFile(name) }
                            .controlSize(.small)
                    }
                }
            }

            Divider()

            HStack {
                TextField("New collection name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(addToNew)
                Button("Add", action: addToNew)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 280)
        .task { load() }
    }

    private func load() {
        do {
            names = try store.collections()
            membership = Set(try names.filter { name in
                try store.collectionMembers(name: name).contains(row.id)
            })
        } catch {
            onError("Collections failed: \(error.localizedDescription)")
        }
    }

    private func toggle(_ name: String) {
        do {
            if membership.contains(name) {
                try store.removeFromCollection(bookmarkID: row.id, name: name)
                membership.remove(name)
            } else {
                try store.addToCollection(bookmarkID: row.id, name: name)
                membership.insert(name)
            }
        } catch {
            onError("Collection update failed: \(error.localizedDescription)")
        }
    }

    private func addToNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try store.addToCollection(bookmarkID: row.id, name: name)
            newName = ""
            load()
        } catch {
            onError("Collection update failed: \(error.localizedDescription)")
        }
    }

    private func exportFile(_ name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(name).html"
        panel.title = "Export “\(name)” as a bookmark file"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            let count = try store.exportCollection(name: name, to: dest)
            onNotice("Exported \(count) links to \(dest.lastPathComponent)")
        } catch {
            onError("Export failed: \(error.localizedDescription)")
        }
    }
}
