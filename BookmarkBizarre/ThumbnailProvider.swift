import SwiftUI
import AppKit
import WebKit
import CryptoKit

// ============================================================================
// ThumbnailProvider — turns a bookmark into a picture, three tiers deep:
//   1. disk/memory cache (sha256(url).png in Application Support)
//   2. live WKWebView snapshot, on demand, max 3 in flight
//   3. placeholder: the export's embedded favicon, else a letter card
//
// Capture is strictly demand-driven (a tile appeared) — with 6,604 bookmarks
// a bulk crawl would be a small DDoS launched from J's Mac. VPN-flagged rows
// are never fetched at all; off-VPN they'd just hang until timeout and burn
// all three capture slots doing it.
// ============================================================================

@MainActor
final class ThumbnailProvider {

    static let shared = ThumbnailProvider()

    private var memory: [String: NSImage] = [:]
    private var placeholders: [String: NSImage] = [:]
    /// Continuations waiting on a capture, keyed by cache key. Several tiles
    /// can show the same URL (dup groups!) — all of them get the one capture.
    private var waiters: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var active: [String: CaptureJob] = [:]
    private var queue: [(key: String, url: URL)] = []
    /// Keys that failed or timed out this session — retrying every scroll-by
    /// would re-burn slots on the same dead hosts.
    private var failed: Set<String> = []

    private let maxConcurrent = 3

    // MARK: - Public

    /// Instant, never nil: favicon from the export if Chrome embedded one,
    /// else a deterministic letter card. Shown while capture runs and kept
    /// when capture can't run.
    func placeholder(for row: BookmarkRow) -> NSImage {
        let key = "ph:" + Self.cacheKey(row.url)
        if let hit = placeholders[key] { return hit }
        let img = faviconCard(for: row) ?? letterCard(for: row)
        placeholders[key] = img
        return img
    }

    /// The real page picture, or nil when it can't/shouldn't be captured.
    /// Safe to call repeatedly — cache hits return immediately, and repeat
    /// requests for an in-flight URL just join the wait.
    func liveThumbnail(for row: BookmarkRow) async -> NSImage? {
        // Never reach for corporate/intranet hosts from here — the flag says
        // the network path doesn't exist without the tunnel.
        guard !row.requiresVPN else { return nil }
        guard let url = URL(string: row.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        let key = Self.cacheKey(row.url)
        if let hit = memory[key] { return hit }
        if failed.contains(key) { return nil }
        if let disk = loadDisk(key) {
            memory[key] = disk
            return disk
        }

        return await withCheckedContinuation { cont in
            waiters[key, default: []].append(cont)
            enqueue(key: key, url: url)
        }
    }

    // MARK: - Scheduling

    /// Folder lost focus: stop rendering it (J's ask, verbatim). Drops the
    /// whole waiting queue and aborts the in-flight webviews so the next
    /// folder starts with all three capture slots free. Cancelled keys are
    /// NOT marked failed — scroll back into that folder and they retry.
    func flushPending() {
        for item in queue {
            for cont in waiters.removeValue(forKey: item.key) ?? [] {
                cont.resume(returning: nil)
            }
        }
        queue.removeAll()

        for (key, job) in active {
            job.cancel()
            for cont in waiters.removeValue(forKey: key) ?? [] {
                cont.resume(returning: nil)
            }
        }
        active.removeAll()
    }

    private func enqueue(key: String, url: URL) {
        // Already capturing or queued: the waiter list handles delivery.
        guard active[key] == nil, !queue.contains(where: { $0.key == key }) else { return }
        if active.count < maxConcurrent {
            start(key: key, url: url)
        } else {
            queue.append((key, url))
        }
    }

    private func start(key: String, url: URL) {
        let job = CaptureJob(url: url) { [weak self] image in
            self?.finish(key: key, image: image)
        }
        active[key] = job
    }

    private func finish(key: String, image: NSImage?) {
        active[key] = nil

        if let image {
            memory[key] = image
            writeDisk(image, key: key)
            trimMemoryIfNeeded()
        } else {
            failed.insert(key)
        }

        for cont in waiters.removeValue(forKey: key) ?? [] {
            cont.resume(returning: image)
        }

        if !queue.isEmpty, active.count < maxConcurrent {
            let next = queue.removeFirst()
            start(key: next.key, url: next.url)
        }
    }

    /// Crude but sufficient cap: a full session over the 6.6k corpus at
    /// ~400px PNGs would otherwise grow without bound. Disk cache keeps the
    /// evicted ones one read away.
    private func trimMemoryIfNeeded() {
        if memory.count > 600 { memory.removeAll() }
    }

    // MARK: - Disk cache

    static func cacheKey(_ url: String) -> String {
        // "@800" is a cache generation stamp: dwell-zoom made 400px captures
        // readably blurry, so the resolution doubled — suffixing the key
        // orphans the old files (harmless) instead of serving them soft.
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() + "@800"
    }

    private func loadDisk(_ key: String) -> NSImage? {
        let file = BMZ.thumbnailDirectory.appendingPathComponent(key + ".png")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(contentsOf: file)
    }

    private func writeDisk(_ image: NSImage, key: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: BMZ.thumbnailDirectory.appendingPathComponent(key + ".png"))
    }

    // MARK: - Placeholders

    private static let cardSize = NSSize(width: 400, height: 300)

    /// Background hue must be stable run-to-run; String.hashValue is salted
    /// per process, so the same host would repaint every launch. SHA256 isn't.
    private static func hue(for host: String) -> CGFloat {
        // SHA256Digest is only a Sequence — no .first property, just
        // first(where:) — so materialize before taking a byte.
        CGFloat(Array(SHA256.hash(data: Data(host.utf8))).first ?? 0) / 255.0
    }

    private func faviconCard(for row: BookmarkRow) -> NSImage? {
        // Chrome exports favicons as "data:image/png;base64,<blob>".
        guard let uri = row.iconURI,
              uri.hasPrefix("data:"),
              let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
              let favicon = NSImage(data: data) else { return nil }

        let host = row.host ?? "?"
        let img = NSImage(size: Self.cardSize)
        img.lockFocus()
        NSColor(hue: Self.hue(for: host), saturation: 0.18, brightness: 0.32, alpha: 1).setFill()
        NSRect(origin: .zero, size: Self.cardSize).fill()
        // Favicons are 16–32px; draw at 64 centered rather than stretching
        // them into mush across the whole card.
        let side: CGFloat = 64
        favicon.draw(in: NSRect(
            x: (Self.cardSize.width - side) / 2,
            y: (Self.cardSize.height - side) / 2,
            width: side, height: side))
        img.unlockFocus()
        return img
    }

    private func letterCard(for row: BookmarkRow) -> NSImage {
        let host = row.host ?? row.scheme ?? "?"
        let letter = String(host.first(where: { $0.isLetter || $0.isNumber }) ?? "•").uppercased()

        let img = NSImage(size: Self.cardSize)
        img.lockFocus()
        NSColor(hue: Self.hue(for: host), saturation: 0.35, brightness: 0.55, alpha: 1).setFill()
        NSRect(origin: .zero, size: Self.cardSize).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 130, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let text = NSAttributedString(string: letter, attributes: attrs)
        let bounds = text.size()
        text.draw(at: NSPoint(
            x: (Self.cardSize.width - bounds.width) / 2,
            y: (Self.cardSize.height - bounds.height) / 2))
        img.unlockFocus()
        return img
    }
}

// MARK: - One capture

/// Owns one offscreen WKWebView for the life of one page load. WKWebView is
/// main-thread-only — creation, load, snapshot and teardown all happen there;
/// only the PNG encode above leaves it (and even that is cheap enough not to
/// bother threading at 3-at-a-time).
@MainActor
private final class CaptureJob: NSObject, WKNavigationDelegate {

    private let webView: WKWebView
    private let completion: (NSImage?) -> Void
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    init(url: URL, completion: @escaping (NSImage?) -> Void) {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        self.completion = completion
        super.init()
        webView.navigationDelegate = self

        // Hard stop: a hanging host must give its slot back. 15s covers slow
        // real pages; anything slower gets the placeholder for the session.
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        webView.load(request)
    }

    /// Abort without reporting failure. `finished` goes true FIRST so the
    /// delegate callbacks that stopLoading provokes (and the timeout) all
    /// no-op — the completion is never called for a cancelled job, because
    /// "J moved to another folder" must not brand the URL as dead.
    func cancel() {
        finished = true
        timeoutWork?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // didFinish fires before JS layout settles; snapshotting immediately
        // yields blank white cards on script-heavy pages. One breath fixes most.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.snapshot()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func snapshot() {
        guard !finished else { return }
        let config = WKSnapshotConfiguration()
        // WebKit does the downscale for us — full 1024pt render delivered
        // at 800pt, no NSImage resize pass needed. 800 not 400 because the
        // dwell zoom blows tiles up ~3x and J reads them, not squints.
        config.snapshotWidth = NSNumber(value: 800)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.finish(image)
        }
    }

    private func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        completion(image)
    }
}

// MARK: - Tile-side view

/// The image half of a tile: placeholder immediately, live capture swapped in
/// when (if) it lands. Lives here rather than GridView so the grid never
/// touches WebKit directly.
struct TileThumbnail: View {
    let row: BookmarkRow
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .quaternaryLabelColor)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: row.url) {
            image = ThumbnailProvider.shared.placeholder(for: row)
            // Tile scrolled away mid-capture? The task is cancelled but the
            // capture completes and caches anyway — next appearance is a hit.
            if let live = await ThumbnailProvider.shared.liveThumbnail(for: row) {
                image = live
            }
        }
    }
}
