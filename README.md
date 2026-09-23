# BookmarkBizarre

Native macOS app for taking a browser bookmark export and turning it into
something you can actually see: a borderless grid of live page tiles you can
hover to enlarge, click to open, and curate in place.

## What it does (v0.1.0 — foundation)

- **Import** a `NETSCAPE-Bookmark-file-1` HTML export (Chrome / Firefox / Safari all emit it)
- **One SQLite per file** — each import becomes its own database in
  `~/Library/Application Support/BookmarkBizarre/Libraries/`, the bookmark
  broken into components: folder tree, title, URL split into
  scheme/host/path/query/fragment, add dates, embedded favicon, tags
- **Inventory** — live evaluation pass: totals, duplicate groups (normalized
  URL collisions), scheme breakdown, top hosts, folder tree, max depth,
  untitled/unparsable counts, date range
- **Grid** — borderless tiles of page snapshots (lazy WKWebView capture with
  disk cache; favicon/letter-card until a capture lands); hover enlarges;
  click opens in the default browser
- **Tile menu** (right edge, on hover) — rename title, mark for removal,
  toggle VPN-required, save link into a named collection; collections export
  back out as a valid bookmark `.html`
- **VPN-aware** — hosts that look intranet-only are flagged at import;
  flagged links can launch your VPN client (Settings → path) before opening
- **Blank slate** — first launch is empty; nothing imports until you say so

## Headless smoke test

```sh
BookmarkBizarre.app/Contents/MacOS/BookmarkBizarre --import bookmarks.html [--dir /path/to/dbdir]
```

Runs the full import pipeline, prints a greppable inventory, exits. This is
how the pipeline is verified without clicking.

## Build

Xcode 16+ (built on 27). Open `BookmarkBizarre.xcodeproj`, sign with the
LIBCSYSTEMS LLC team (46AXDWA6F8), run. No external dependencies — SwiftUI,
AppKit, WebKit, CryptoKit, and the system SQLite3 only.

## Architecture

| File | Layer | Role |
|---|---|---|
| `Models.swift` | contract | shared types + `LibraryStore` protocol — the one file both layers obey |
| `NetscapeParser.swift` | data | line-scanner for the not-actually-HTML export format |
| `SQLiteStore.swift` | data | schema, import transaction, dup grouping, inventory SQL, collection export |
| `Headless.swift` | data | `--import` CLI path |
| `LibraryManager.swift` | ui | sidebar state, import flow, rescan |
| `ContentView.swift` | ui | split view, blank slate, Grid/Inventory switch |
| `GridView.swift` | ui | the tile grid: hover-zoom, open-in-browser, right-edge menu |
| `ThumbnailProvider.swift` | ui | capped WKWebView snapshots + disk cache + placeholders |
| `InventoryView.swift` | ui | the dashboard read of the inventory |
