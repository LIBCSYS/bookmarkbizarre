# BookmarkBizarre

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange)

Native macOS app that turns years of accumulated browser bookmarks into
something you can actually see: a borderless grid of live page tiles you can
hover to enlarge, click to open, and curate in place. Import six thousand
bookmarks; find the forty you still care about.

## What it does (v0.3.0)

- **Import from anywhere** — pull straight from installed browser profiles
  (Chrome / Edge / Brave JSON, Firefox `places.sqlite`, Safari plist*), or
  open any `NETSCAPE-Bookmark-file-1` HTML export
- **One SQLite per library** — each import becomes its own database in
  `~/Library/Application Support/BookmarkBizarre/Libraries/`, every bookmark
  broken into components: folder tree, title, URL split into
  scheme/host/path/query/fragment, add dates, embedded favicon, tags
- **Explorer layout** — folder tree in the left sidebar (Bookmarks Bar first);
  the portal shows only the folder you clicked, so a 6,000-bookmark file never
  becomes a 6,000-tile wall
- **Live tiles** — lazy WKWebView page snapshots (800px, disk-cached;
  favicon/letter-card until a capture lands); a tile-size slider runs from
  see-everything small to 3-across big
- **Dwell zoom** — rest the pointer on a tile and it grows to a readable size,
  edge-aware (tiles near the viewport border grow inward) and drawn in an
  overlay layer so neighbors never cover it; click opens the default browser
- **Inventory** — live evaluation pass: totals, duplicate groups (normalized
  URL collisions), scheme breakdown, top hosts, folder tree, max depth,
  untitled/unparsable counts, date range
- **Tile menu** (right edge, on hover) — rename, mark for removal, toggle
  VPN-required, save into a named collection; collections export back out as
  a valid bookmark `.html`
- **Collections you can delete** — trash a collection from the tile menu
  (inline confirm); only the grouping goes, never the bookmarks, and Undo
  puts it back
- **Folder filter** — pick a folder in the sidebar or the Inventory tree and
  the grid shows that folder plus everything beneath it, with a breadcrumb
  and a one-click clear chip
- **Remove Library** — right-click a library (or press Delete): it leaves the
  sidebar, its database is parked in `Libraries/Removed`, the original export
  is untouched; Undo or *Import → Restore Removed Library* brings it back
- **Shared thumbnails** — captures are keyed on the normalized URL (case,
  default ports, trailing slash, utm_/fbclid/gclid, fragment), so cosmetic
  duplicates share one picture; existing captures are re-keyed on first launch
- **VPN-aware** — hosts that look intranet-only are flagged at import; flagged
  links can launch your VPN client (Settings → path) before opening
- **Blank slate** — first launch is empty; nothing imports until you say so

\* Safari import reads `~/Library/Safari/Bookmarks.plist` and needs
Full Disk Access granted to the app.

## Headless smoke test

```sh
BookmarkBizarre.app/Contents/MacOS/BookmarkBizarre --import bookmarks.html [--dir /path/to/dbdir]
```

Runs the full import pipeline, prints a greppable inventory, exits. This is
how the pipeline is verified without clicking.

## Tests

```sh
xcodebuild test -project BookmarkBizarre.xcodeproj -scheme BookmarkBizarre
```

Unit tests cover URL normalization, collection delete/undo, the thumbnail
re-key migration, and library remove/restore. They run in temp folders only.

## App icon

`design/AppIcon.svg` is the source; `design/render_icon.sh` rasterizes every
macOS size straight from the vector into `Assets.xcassets/AppIcon.appiconset`.

## Build

Xcode 16+ (built on 27). Open `BookmarkBizarre.xcodeproj`, set your own
development team, run. No external dependencies — SwiftUI, AppKit, WebKit,
CryptoKit, and the system SQLite3 only.

## Architecture

| File | Layer | Role |
|---|---|---|
| `Models.swift` | contract | shared types + `LibraryStore` protocol — the one file both layers obey |
| `NetscapeParser.swift` | data | line-scanner for the not-actually-HTML export format |
| `BrowserImport.swift` | data | direct profile readers: Chrome-family JSON, Firefox places.sqlite, Safari plist |
| `SQLiteStore.swift` | data | schema, import transaction, dup grouping, inventory SQL, collection export |
| `Headless.swift` | data | `--import` CLI path |
| `LibraryManager.swift` | ui | sidebar state, import flow, rescan |
| `ContentView.swift` | ui | split view, blank slate, Grid/Inventory switch |
| `GridView.swift` | ui | the tile grid: sidebar tree, dwell zoom, open-in-browser, right-edge menu |
| `ThumbnailProvider.swift` | ui | capped WKWebView snapshots + disk cache + placeholders |
| `InventoryView.swift` | ui | the dashboard read of the inventory |

## Privacy

Everything is local. No network calls except the page captures you ask for
(the tiles are literally your bookmarks loading). No telemetry, no accounts,
nothing leaves the machine.

## License

MIT — see [LICENSE](LICENSE). Issues and PRs welcome.
