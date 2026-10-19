import XCTest
@testable import BookmarkBizarre

// Store tests run against a throwaway library in a temp directory — never
// J's real Application Support folder. No teardown delete (rule #1); macOS
// reaps $TMPDIR.
final class LibraryStoreTests: XCTestCase {

    private var dir: URL!
    private var store: (any LibraryStore)!

    private let sample = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3>
        <DL><p>
            <DT><A HREF="https://example.com/a">A</A>
            <DT><A HREF="https://example.com/b">B</A>
            <DT><H3>Nested</H3>
            <DL><p>
                <DT><A HREF="https://example.com/c">C</A>
            </DL><p>
        </DL><p>
        <DT><A HREF="https://example.com/a/?utm_source=x">A again</A>
    </DL><p>
    """

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmz-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("sample.html")
        try sample.write(to: src, atomically: true, encoding: .utf8)
        let info = try Importer.importFile(at: src, into: dir)
        store = try openLibrary(at: info.fileURL)
    }


    private func allIDs() throws -> [Int] {
        try store.bookmarks(search: "", scope: .all, limit: 100, offset: 0).map(\.id)
    }

    func testImportFoundAllRowsAndDupGroup() throws {
        let rows = try store.bookmarks(search: "", scope: .all, limit: 100, offset: 0)
        XCTAssertEqual(rows.count, 4)
        // "/a" and "/a/?utm_source=x" are one page under the shared normalizer
        let grouped = rows.filter { $0.dupGroup != nil }
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped.map(\.normURL)), ["https://example.com/a"])
    }

    func testDeleteCollectionRemovesGroupingButNeverBookmarks() throws {
        let ids = try allIDs()
        try store.addToCollection(bookmarkID: ids[0], name: "Keep")
        try store.addToCollection(bookmarkID: ids[1], name: "Keep")
        try store.addToCollection(bookmarkID: ids[2], name: "Other")

        let removed = try store.deleteCollection(name: "Keep")

        XCTAssertEqual(removed, [ids[0], ids[1]])
        XCTAssertEqual(try store.collections(), ["Other"], "only the named collection goes")
        XCTAssertEqual(try store.bookmarkTotal(search: "", scope: .all), 4, "bookmarks untouched")
        XCTAssertEqual(try store.collectionMembers(name: "Other"), [ids[2]])
    }

    func testDeleteCollectionIsUndoable() throws {
        let ids = try allIDs()
        try store.addToCollection(bookmarkID: ids[0], name: "Reading")
        try store.addToCollection(bookmarkID: ids[3], name: "Reading")
        let removed = try store.deleteCollection(name: "Reading")
        XCTAssertTrue(try store.collections().isEmpty)

        try store.restoreCollection(name: "Reading", members: removed)

        XCTAssertEqual(try store.collections(), ["Reading"])
        XCTAssertEqual(try store.collectionMembers(name: "Reading"), Set([ids[0], ids[3]]))
    }

    func testRestoreSkipsVanishedIDs() throws {
        let ids = try allIDs()
        try store.restoreCollection(name: "X", members: [ids[0], 999_999])
        XCTAssertEqual(try store.collectionMembers(name: "X"), [ids[0]])
    }

    func testDeleteMissingCollectionIsHarmless() throws {
        XCTAssertEqual(try store.deleteCollection(name: "nope"), [])
    }

    func testFolderScopeCoversSubtree() throws {
        let bar = try XCTUnwrap(try store.folders().first { $0.isToolbar })
        XCTAssertEqual(try store.bookmarkTotal(search: "", scope: .folder(bar.id)), 3)
        let nested = try XCTUnwrap(try store.folders().first { $0.name == "Nested" })
        XCTAssertEqual(try store.bookmarkTotal(search: "", scope: .folder(nested.id)), 1)
    }
}
