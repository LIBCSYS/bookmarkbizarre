import XCTest
@testable import BookmarkBizarre

final class ThumbnailMigrationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmz-thumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }


    private func file(_ key: String) -> URL { dir.appendingPathComponent(key + ".png") }
    private func touch(_ key: String, _ body: String) throws {
        try Data(body.utf8).write(to: file(key))
    }

    func testLegacyRawKeyIsRenamedOntoNormalizedKey() throws {
        let raw = "https://Example.com/page/?utm_source=x"
        let oldKey = ThumbnailProvider.cacheKey(raw)
        let newKey = ThumbnailProvider.cacheKey(URLNormalizer.normalize(raw))
        try touch(oldKey, "capture")

        let r = ThumbnailCacheMigration.migrate(rawURLs: [raw], in: dir)

        XCTAssertEqual(r.moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(oldKey).path))
        XCTAssertEqual(try String(contentsOf: file(newKey), encoding: .utf8), "capture",
                       "the capture itself survives the re-key")
    }

    func testCollidingVariantsNeverOverwriteOrDelete() throws {
        let a = "https://example.com/x/"
        let b = "https://example.com/x?utm_medium=y"
        try touch(ThumbnailProvider.cacheKey(a), "A")
        try touch(ThumbnailProvider.cacheKey(b), "B")

        let r = ThumbnailCacheMigration.migrate(rawURLs: [a, b], in: dir)

        XCTAssertEqual(r.moved, 1)
        XCTAssertEqual(r.orphaned, 1)
        // 2 files in → 2 files out: one re-keyed, one left in place
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 2)
    }

    func testAlreadyNormalURLNeedsNoMove() throws {
        let url = "https://example.com/x"
        try touch(ThumbnailProvider.cacheKey(url), "same")
        let r = ThumbnailCacheMigration.migrate(rawURLs: [url], in: dir)
        XCTAssertEqual(r, .init(moved: 0, alreadyCurrent: 1, orphaned: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(ThumbnailProvider.cacheKey(url)).path))
    }

    func testMissingFilesAreIgnored() {
        let r = ThumbnailCacheMigration.migrate(rawURLs: ["https://nothing.example/a/"], in: dir)
        XCTAssertEqual(r.moved, 0)
    }
}
