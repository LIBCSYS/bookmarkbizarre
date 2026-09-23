import Foundation

// ============================================================================
// Headless.swift — `BookmarkBizarre --import <file.html> [--dir <dbdir>]`
// The whole import pipeline is drivable from a terminal, so the pipeline can
// be smoke-tested (and scripted) without anyone clicking through the UI.
// Output is one fact per line, grep-able, stable.
// ============================================================================

enum Headless {

    /// Called first thing from the App init. Returns immediately for a normal
    /// GUI launch; with --import it runs the pipeline and never returns.
    static func runIfNeeded() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--import") else { return }
        guard args.count > flag + 1 else { die("--import needs a file path") }

        let source = URL(fileURLWithPath: (args[flag + 1] as NSString).expandingTildeInPath)

        var directory = BMZ.librariesDirectory
        if let d = args.firstIndex(of: "--dir"), args.count > d + 1 {
            directory = URL(fileURLWithPath: (args[d + 1] as NSString).expandingTildeInPath,
                            isDirectory: true)
            // --dir is a test convenience; creating it beats erroring on a
            // path the caller clearly wants
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        do {
            let info: LibraryInfo
            do {
                info = try Importer.importFile(at: source, into: directory)
            } catch let err as ImportError {
                die(String(describing: err))
            }
            let store = try openLibrary(at: info.fileURL)
            let inv = try store.inventory()

            print("imported: \(info.fileURL.path)")
            print("bookmarks=\(inv.bookmarkCount) folders=\(inv.folderCount) " +
                  "hosts=\(inv.uniqueHosts) dupGroups=\(inv.dupGroups) dupExtras=\(inv.dupExtras) " +
                  "maxDepth=\(inv.maxDepth) vpn=\(inv.vpnCount) skipped=\(inv.skippedLines)")
            for s in inv.schemes { print("scheme \(s.name) \(s.count)") }
            for h in inv.topHosts { print("tophost \(h.name) \(h.count)") }
            exit(0)
        } catch {
            die("\(error)")
        }
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
