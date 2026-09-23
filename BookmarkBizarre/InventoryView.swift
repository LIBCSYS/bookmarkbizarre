import SwiftUI

// ============================================================================
// InventoryView — the evaluation read of one library: what came in, how it
// decomposes, and what the flags currently say. All numbers are live SQL via
// store.inventory(); nothing here is cached, so flag edits in the grid show
// up the moment you switch tabs.
// ============================================================================

struct InventoryView: View {
    let store: any LibraryStore
    @EnvironmentObject private var manager: LibraryManager

    @State private var inv: Inventory?
    @State private var tree: [FolderNode] = []

    var body: some View {
        ScrollView {
            if let inv {
                VStack(alignment: .leading, spacing: 32) {
                    statGrid(inv)

                    HStack(alignment: .top, spacing: 32) {
                        rankedCard(title: "Schemes", rows: inv.schemes)
                        rankedCard(title: "Top hosts", rows: inv.topHosts)
                    }

                    folderCard
                }
                .padding(32)
                .frame(maxWidth: 1100, alignment: .leading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(60)
            }
        }
        .task { load() }
    }

    private func load() {
        do {
            inv = try store.inventory()
            tree = FolderNode.build(from: try store.folders())
        } catch {
            manager.fail("Inventory failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stat tiles

    private func statGrid(_ inv: Inventory) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14)],
                  alignment: .leading, spacing: 14) {
            StatTile(value: inv.bookmarkCount.formatted(), label: "Bookmarks")
            StatTile(value: inv.folderCount.formatted(), label: "Folders")
            StatTile(value: inv.uniqueHosts.formatted(), label: "Unique hosts")
            StatTile(value: inv.dupGroups.formatted(), label: "Duplicate groups")
            StatTile(value: inv.dupExtras.formatted(), label: "Surplus duplicates",
                     footnote: "rows beyond the first per group")
            StatTile(value: inv.vpnCount.formatted(), label: "VPN-flagged")
            StatTile(value: inv.removalCount.formatted(), label: "Marked for removal")
            StatTile(value: inv.maxDepth.formatted(), label: "Deepest folder")
            StatTile(value: inv.untitled.formatted(), label: "Untitled")
            StatTile(value: inv.unparsedHosts.formatted(), label: "Unparsed URLs",
                     footnote: "http(s) that would not decompose")
            StatTile(value: inv.skippedLines.formatted(), label: "Skipped lines",
                     footnote: "parser refused to guess")
            StatTile(value: dateRange(inv), label: "Added between")
        }
    }

    private func dateRange(_ inv: Inventory) -> String {
        func fmt(_ secs: Int?) -> String? {
            guard let secs, secs > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(secs))
                .formatted(.dateTime.month(.abbreviated).year())
        }
        guard let a = fmt(inv.oldestAdd), let b = fmt(inv.newestAdd) else { return "—" }
        return a == b ? a : "\(a) – \(b)"
    }

    // MARK: - Ranked bars

    private func rankedCard(title: String, rows: [(name: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            if rows.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                let peak = rows.map(\.count).max() ?? 1
                ForEach(rows, id: \.name) { row in
                    HStack(spacing: 10) {
                        Text(row.name)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 190, alignment: .leading)
                        // Proportional bar, no chart library — one capsule
                        // under another, width by share of the column peak.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.8))
                                    .frame(width: max(3, geo.size.width * CGFloat(row.count) / CGFloat(peak)))
                            }
                        }
                        .frame(height: 8)
                        Text(row.count.formatted())
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Folder tree

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder structure")
                .font(.title3.weight(.semibold))
            if tree.isEmpty {
                Text("Flat file — no folders")
                    .foregroundStyle(.secondary)
            } else {
                OutlineGroup(tree, children: \.children) { node in
                    HStack(spacing: 8) {
                        Image(systemName: node.row.isToolbar ? "menubar.rectangle" : "folder")
                            .foregroundStyle(.secondary)
                        Text(node.row.name.isEmpty ? "(unnamed)" : node.row.name)
                        Spacer()
                        if node.row.directCount > 0 {
                            Text(node.row.directCount.formatted())
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Pieces

struct StatTile: View {
    let value: String
    let label: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// FolderRow list → tree for OutlineGroup. `children` must be nil (not empty)
/// at the leaves or OutlineGroup renders every leaf with a disclosure chevron.
struct FolderNode: Identifiable {
    let row: FolderRow
    var children: [FolderNode]?
    var id: Int { row.id }

    static func build(from rows: [FolderRow]) -> [FolderNode] {
        let byParent = Dictionary(grouping: rows, by: { $0.parentID })
        func nodes(under parent: Int?) -> [FolderNode]? {
            guard let kids = byParent[parent], !kids.isEmpty else { return nil }
            return kids.map { FolderNode(row: $0, children: nodes(under: $0.id)) }
        }
        return nodes(under: nil) ?? []
    }
}
