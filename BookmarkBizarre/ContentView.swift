import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// ContentView — the window: sidebar of imported libraries on the left, the
// selected library (grid or inventory) on the right, one banner lane on top.
// ============================================================================

enum DetailMode: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case inventory = "Inventory"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var manager: LibraryManager
    @State private var mode: DetailMode = .grid
    @State private var search = ""
    @State private var showImporter = false
    // Explorer state: the folder cascade lives in the SIDEBAR (J: "have the
    // folders expand on the left side... Bookmarks Bar first"), so its state
    // lives here at window level, not inside the detail pane.
    @State private var folderID: Int?
    @State private var folderRows: [FolderRow] = []
    @State private var folderTree: [FolderNode] = []

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            detail
        }
        .overlay(alignment: .top) { bannerLane }
        .task(id: manager.selectedID) { loadFolders() }
        .fileImporter(
            isPresented: $showImporter,
            // Exports are .html, but Firefox occasionally hands out .txt —
            // accepting plain text costs nothing, the parser decides anyway.
            allowedContentTypes: [.html, .plainText]
        ) { result in
            if case .success(let url) = result { manager.importFile(url) }
        }
    }

    // MARK: - Sidebar

    /// Fresh cascade whenever the selected library changes. Read through a
    /// short-lived store handle — the detail pane owns its own.
    private func loadFolders() {
        folderID = nil
        folderRows = []
        folderTree = []
        guard let lib = manager.selected else { return }
        do {
            let db = try openLibrary(at: lib.fileURL)
            folderRows = try db.folders()
            folderTree = FolderNode.build(from: folderRows)
        } catch {
            manager.fail("Could not read folders: \(error.localizedDescription)")
        }
    }

    private var sidebar: some View {
        List(selection: $manager.selectedID) {
            Section("Libraries") {
                ForEach(manager.libraries) { lib in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lib.name)
                            .font(.body)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(lib.bookmarkCount) bookmarks")
                            if let date = lib.importedAt {
                                Text("·")
                                Text(date, format: .dateTime.month(.abbreviated).day().year())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(lib.id)
                }
            }

            // The explorer cascade: Bookmarks Bar first (file order), each
            // folder expanding in place. Selecting one shows its whole
            // subtree's pages in the portal; the root row shows everything.
            if !folderTree.isEmpty {
                Section("Folders") {
                    sideFolderRow(id: nil, name: "All Bookmarks",
                                  symbol: "house", count: nil)
                    OutlineGroup(folderTree, children: \.children) { node in
                        sideFolderRow(id: node.row.id,
                                      name: node.row.name.isEmpty ? "(untitled)" : node.row.name,
                                      symbol: node.row.isToolbar ? "menubar.rectangle" : "folder",
                                      count: node.row.directCount)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                ImportMenu(showImporter: $showImporter)
                Spacer()
                VPNSettingsButton()
            }
            .padding(10)
            .background(.bar)
        }
    }

    /// One row of the cascade. Plain buttons, not List selection — the List's
    /// selection already belongs to the library rows, and mixing two selection
    /// types in one List is how sidebars start fighting themselves.
    private func sideFolderRow(id: Int?, name: String, symbol: String, count: Int?) -> some View {
        Button {
            folderID = id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(folderID == id ? Color.accentColor : Color.secondary)
                Text(name)
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(folderID == id ? .semibold : .regular)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if manager.libraries.isEmpty {
            blankSlate
        } else if let lib = manager.selected {
            LibraryDetailView(library: lib, mode: $mode, search: $search,
                              folderID: $folderID, folderRows: folderRows)
                // Fresh state (store, pages, scroll) per library — .id() is
                // what prevents library A's grid bleeding into library B.
                .id(lib.id)
        } else {
            Text("Select a library")
                .foregroundStyle(.secondary)
        }
    }

    /// First-launch view. The app owns no data until J hands it a file.
    private var blankSlate: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("BookmarkBizarre")
                .font(.largeTitle.weight(.semibold))
            Text("Import a bookmark file to break it into components and browse it as a wall of pages.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                showImporter = true
            } label: {
                Label("Import Bookmark File…", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Banner

    @ViewBuilder
    private var bannerLane: some View {
        if let b = manager.banner {
            HStack(spacing: 8) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(b.isError ? Color.orange : Color.accentColor)
                Text(b.text)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button {
                    manager.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: b) {
                // Notices clear themselves; errors stay until dismissed —
                // an error that vanishes on its own was never read.
                guard !b.isError else { return }
                try? await Task.sleep(for: .seconds(4))
                if manager.banner == b { manager.banner = nil }
            }
        }
    }
}

// MARK: - Library detail (store lifecycle + mode switch)

struct LibraryDetailView: View {
    let library: LibraryInfo
    @Binding var mode: DetailMode
    @Binding var search: String
    // Navigation belongs to the sidebar cascade now; the detail pane just
    // renders whatever slice it names.
    @Binding var folderID: Int?
    let folderRows: [FolderRow]
    @EnvironmentObject private var manager: LibraryManager
    @State private var store: (any LibraryStore)?

    var body: some View {
        Group {
            if let store {
                switch mode {
                case .grid:
                    GridView(store: store, search: search,
                             folderID: $folderID, folderRows: folderRows)
                case .inventory:
                    InventoryView(store: store)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search whole file")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(DetailMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(library.name)
        .task(id: library.id) {
            do {
                store = try openLibrary(at: library.fileURL)
            } catch {
                manager.fail("Could not open \(library.name): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Import menu

/// "Import" grew from one button into a menu the moment direct browser pull
/// landed: a file picker at the top, then one row per detected profile.
/// Detection re-runs on every open — profiles appear/disappear as browsers
/// are installed or wiped, and a stale menu would offer dead paths.
struct ImportMenu: View {
    @Binding var showImporter: Bool
    @EnvironmentObject private var manager: LibraryManager
    @State private var profiles: [BrowserProfile] = []

    var body: some View {
        Menu {
            Button {
                showImporter = true
            } label: {
                Label("Import Bookmark File…", systemImage: "doc.badge.plus")
            }

            if !profiles.isEmpty {
                Divider()
                ForEach(profiles) { p in
                    Button {
                        manager.importBrowser(p)
                    } label: {
                        // Unreadable (Safari without Full Disk Access) stays
                        // clickable on purpose: the resulting error carries
                        // the fix instructions, a disabled row explains nothing.
                        Label(p.readable ? p.displayLabel
                                         : "\(p.displayLabel) — needs Full Disk Access",
                              systemImage: p.kind.symbolName)
                    }
                }
            }
        } label: {
            Label("Import…", systemImage: "square.and.arrow.down")
        }
        .onAppear { profiles = BrowserImporter.detectProfiles() }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - VPN client setting

/// The whole "Settings" surface for now: where the VPN client lives. Stored
/// in UserDefaults under BMZ.vpnClientPathKey; GridView reads it at click
/// time, so changes apply immediately with no relaunch.
struct VPNSettingsButton: View {
    @AppStorage(BMZ.vpnClientPathKey) private var vpnClientPath = ""
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("VPN client for gated bookmarks")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("VPN client application")
                    .font(.headline)
                Text("Launched before opening any bookmark flagged “requires VPN”. Leave empty to open links directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 300, alignment: .leading)
                HStack {
                    TextField("/Applications/YourVPN.app", text: $vpnClientPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Choose…") { choose() }
                }
            }
            .padding(14)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            vpnClientPath = url.path
        }
    }
}
