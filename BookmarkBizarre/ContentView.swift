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
                Button {
                    showImporter = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
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

    var body: some View {
        Group {
            if let store {
                switch mode {
                case .grid:
                    GridView(store: store, search: search)
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
