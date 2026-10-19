import XCTest
@testable import BookmarkBizarre

// Remove Library must MOVE, never delete. These tests drive Importer.remove /
// restore entirely inside a temp folder (parking dir injected), so the real
// Application Support tree is never touched. Nothing is deleted afterwards
// either — J's rule #1 covers test fixtures too; macOS reaps $TMPDIR.
final class LibraryRemovalTests: XCTestCase {

    private var dir: URL!
    private var parking: URL { dir.appendingPathComponent("Removed", isDirectory: true) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmz-rm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func importSample(_ marker: String) throws -> LibraryInfo {
        let src = dir.appendingPathComponent("rmtest-\(marker).html")
        try """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://example.com/\(marker)">\(marker)</A>
        </DL><p>
        """.write(to: src, atomically: true, encoding: .utf8)
        return try Importer.importFile(at: src, into: dir)
    }

    func testRemoveMovesFileAndKeepsSource() throws {
        let info = try importSample(UUID().uuidString)
        let source = URL(fileURLWithPath: info.sourcePath)

        let dest = try Importer.remove(dbURL: info.fileURL, parkingIn: parking)

        XCTAssertFalse(FileManager.default.fileExists(atPath: info.fileURL.path), "gone from the scan dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "but still on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source .html untouched")
        XCTAssertEqual(try Importer.info(for: dest).bookmarkCount, 1, "parked DB still opens")
    }

    func testRestoreBringsItBack() throws {
        let info = try importSample(UUID().uuidString)
        let dest = try Importer.remove(dbURL: info.fileURL, parkingIn: parking)

        let back = try Importer.restore(removedURL: dest, into: dir)

        XCTAssertEqual(back.fileURL.lastPathComponent, info.fileURL.lastPathComponent)
        XCTAssertEqual(back.bookmarkCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRestoreRefusesWhenReimportedMeanwhile() throws {
        let marker = UUID().uuidString
        let info = try importSample(marker)
        let dest = try Importer.remove(dbURL: info.fileURL, parkingIn: parking)
        _ = try importSample(marker)   // same bytes → same sha8 → live twin

        XCTAssertThrowsError(try Importer.restore(removedURL: dest, into: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "refused restore leaves the parked file alone")
    }
}
