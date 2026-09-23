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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detail
        }
        .overlay(alignment: .top) { bannerLane }
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if manager.libraries.isEmpty {
            blankSlate
        } else if let lib = manager.selected {
            LibraryDetailView(library: lib, mode: $mode, search: $search)
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
    @EnvironmentObject private var manager: LibraryManager
    @State private var store: (any LibraryStore)?
    // Where the grid is standing in the folder tree. nil = top level — the
    // drill-down entry point, NOT "everything": the grid never loads the
    // whole file at once. The tree is loaded once per library alongside the
    // store — 407 rows, not worth lazy-loading.
    @State private var folderID: Int?
    @State private var folderRows: [FolderRow] = []
    @State private var folderTree: [FolderNode] = []
    @State private var folderNames: [Int: String] = [:]

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
        .searchable(text: $search, placement: .toolbar, prompt: "Filter title, URL, host")
        .toolbar {
            // Folder scope only means anything in the grid; hiding it in
            // inventory keeps the toolbar honest about what it affects.
            if mode == .grid {
                ToolbarItem(placement: .navigation) {
                    FolderPicker(tree: folderTree, names: folderNames, selection: $folderID)
                }
            }
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
                folderRows = try store?.folders() ?? []
                folderTree = FolderNode.build(from: folderRows)
                folderNames = Dictionary(uniqueKeysWithValues: folderRows.map { ($0.id, $0.name) })
            } catch {
                manager.fail("Could not open \(library.name): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Folder picker

/// Toolbar entry point for walking the folder tree: a button naming the
/// current scope, a popover with the full outline. A Menu would work too,
/// but 407 folders as nested submenus is a hedge maze — a scrollable tree
/// with disclosure triangles matches how J already navigates them in the
/// browser's own manager.
struct FolderPicker: View {
    let tree: [FolderNode]
    let names: [Int: String]
    @Binding var selection: Int?
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selection == nil ? "house" : "folder.fill")
                Text(selection.flatMap { names[$0] } ?? "Top Level")
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help("Show one folder's bookmarks")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(id: nil, name: "Top Level", count: nil, depth: 0)
                    Divider()
                        .padding(.vertical, 4)
                    OutlineGroup(tree, children: \.children) { node in
                        row(id: node.row.id, name: node.row.name,
                            count: node.row.directCount, depth: 0)
                    }
                }
                .padding(10)
            }
            .frame(width: 320, height: 420)
        }
    }

    private func row(id: Int?, name: String, count: Int?, depth: Int) -> some View {
        Button {
            selection = id
            showPopover = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection == id ? "checkmark.circle.fill" : "folder")
                    .foregroundStyle(selection == id ? Color.accentColor : Color.secondary)
                    .font(.system(size: 11))
                Text(name.isEmpty ? "(untitled)" : name)
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
        .padding(.vertical, 2)
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
