import XCTest
@testable import BookmarkBizarre

// The normalizer is the cache key AND the dup-group key, so every rule here
// is a promise two layers depend on. One assertion per rule keeps a failure
// pointing at the rule that broke.
final class URLNormalizerTests: XCTestCase {

    private func n(_ s: String) -> String { URLNormalizer.normalize(s) }

    func testLowercasesSchemeAndHostButNotPath() {
        XCTAssertEqual(n("HTTPS://Example.COM/Some/Path"), "https://example.com/Some/Path")
    }

    func testStripsDefaultPortsKeepsOthers() {
        XCTAssertEqual(n("https://example.com:443/a"), "https://example.com/a")
        XCTAssertEqual(n("http://example.com:80/a"), "http://example.com/a")
        // A non-default port is a different server — the old rules dropped it.
        XCTAssertEqual(n("http://example.com:8080/a"), "http://example.com:8080/a")
        XCTAssertEqual(n("https://example.com:80/a"), "https://example.com:80/a")
    }

    func testStripsTrailingSlash() {
        XCTAssertEqual(n("https://example.com/"), "https://example.com")
        XCTAssertEqual(n("https://example.com"), "https://example.com")
        XCTAssertEqual(n("https://example.com/docs/"), "https://example.com/docs")
    }

    func testDropsTrackingParamsKeepsRealOnesSorted() {
        XCTAssertEqual(n("https://example.com/a?utm_source=x&utm_medium=y"), "https://example.com/a")
        XCTAssertEqual(n("https://example.com/a?fbclid=abc"), "https://example.com/a")
        XCTAssertEqual(n("https://example.com/a?gclid=abc&id=7"), "https://example.com/a?id=7")
        XCTAssertEqual(n("https://example.com/a?UTM_Campaign=z&b=2&a=1"), "https://example.com/a?a=1&b=2")
    }

    func testDropsFragment() {
        XCTAssertEqual(n("https://example.com/a#section-2"), "https://example.com/a")
        XCTAssertEqual(n("https://example.com/a?q=1#top"), "https://example.com/a?q=1")
    }

    func testDropsUserInfo() {
        XCTAssertEqual(n("https://bob:secret@example.com/a"), "https://example.com/a")
    }

    func testCosmeticVariantsCollapseToOneKey() {
        let variants = [
            "https://Example.com/article/",
            "https://example.com:443/article?utm_source=newsletter",
            "HTTPS://EXAMPLE.COM/article#comments",
            "https://example.com/article?fbclid=IwAR0",
        ]
        XCTAssertEqual(Set(variants.map(n)), ["https://example.com/article"])
        let keys = Set(variants.map { ThumbnailProvider.cacheKey(URLNormalizer.normalize($0)) })
        XCTAssertEqual(keys.count, 1, "dup-group members must share one thumbnail")
    }

    func testHostlessSchemesAreLeftVerbatim() {
        let js = "javascript:alert('Hi')"
        XCTAssertEqual(n(js), js)
        XCTAssertEqual(n("  mailto:J@Example.com "), "mailto:J@Example.com")
    }

    func testMalformedURLSalvagesSchemeAndHost() {
        XCTAssertEqual(n("http://Bad Host.com/with spaces"), "http://bad host.com")
    }

    func testRowExposesNormURL() {
        let row = BookmarkRow(id: 1, title: "t", url: "https://Example.com/x/?utm_x=1",
                              scheme: "https", host: "example.com", folderID: nil, position: 0,
                              addDate: nil, dupGroup: nil, iconURI: nil,
                              markedForRemoval: false, requiresVPN: false)
        XCTAssertEqual(row.normURL, "https://example.com/x")
    }
}
