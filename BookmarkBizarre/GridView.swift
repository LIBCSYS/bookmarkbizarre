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
    @EnvironmentObject private var manager: LibraryManager

    @State private var rows: [BookmarkRow] = []
    @State private var total = 0
    @State private var loading = false
    /// Only one tile may be enlarged; tracking the id here (not per-tile)
    /// lets the grid raise that tile's zIndex so it draws over its neighbors.
    @State private var hoveredID: Int?

    private let pageSize = 400

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 6)],
                spacing: 6
            ) {
                ForEach(rows) { row in
                    BookmarkTile(
                        row: row,
                        store: store,
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
            .padding(12)

            footer
        }
        .task(id: search) {
            // Debounce: typing "github" is 6 keystrokes, not 6 SQL sweeps.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Text(total == 0 ? "No bookmarks match" : "Showing \(rows.count) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Data

    private func reload() {
        do {
            total = try store.bookmarkTotal(search: search, folderID: nil)
            rows = try store.bookmarks(search: search, folderID: nil, limit: pageSize, offset: 0)
        } catch {
            manager.fail("Load failed: \(error.localizedDescription)")
        }
    }

    private func loadMore() {
        guard rows.count < total, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try store.bookmarks(search: search, folderID: nil, limit: pageSize, offset: rows.count)
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
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onChanged: (BookmarkRow) -> Void
    let onNotice: (String) -> Void
    let onError: (String) -> Void

    @AppStorage(BMZ.vpnClientPathKey) private var vpnClientPath = ""
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showCollect = false

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
        .scaleEffect(isHovered ? 1.6 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.35 : 0), radius: isHovered ? 18 : 0, y: 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
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
