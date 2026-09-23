import Foundation

// ============================================================================
// Headless.swift — `BookmarkBizarre --import <file.html> [--dir <dbdir>]`
// The whole import pipeline is drivable from a terminal, so the pipeline can
// be smoke-tested (and scripted) without anyone clicking through the UI.
// Output is one fact per line, grep-able, stable.
// ============================================================================

enum Headless {

    /// Called first thing from the App init. Returns immediately for a normal
    /// GUI launch; with --import or --import-browser it runs the pipeline and
    /// never returns.
    static func runIfNeeded() {
        let args = CommandLine.arguments
        let fileFlag = args.firstIndex(of: "--import")
        let browserFlag = args.firstIndex(of: "--import-browser")
        guard let flag = fileFlag ?? browserFlag else { return }
        guard args.count > flag + 1 else { die("--import/--import-browser needs a file path") }

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
                info = fileFlag != nil
                    ? try Importer.importFile(at: source, into: directory)
                    : try importBrowserFile(at: source, into: directory)
            } catch let err as ImportError {
                die(String(describing: err))
            } catch let err as BrowserImportError {
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

    /// --import-browser sniffs the format from the bytes, because the names
    /// lie: Chrome's file has no extension, Firefox's is .sqlite, and a
    /// Safari plist can be binary or XML under the same name.
    private static func importBrowserFile(at source: URL, into directory: URL) throws -> LibraryInfo {
        var head = Data()
        if let fh = FileHandle(forReadingAtPath: source.path) {
            head = (try? fh.read(upToCount: 16)) ?? Data()
            try? fh.close()
        }
        let kind: BrowserKind
        if head.starts(with: Array("SQLite format 3".utf8)) {
            kind = .firefox
        } else if head.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d }).first
                    == UInt8(ascii: "{") {
            kind = .chrome
        } else {
            kind = .safari   // bplist00 and <?xml both land here; the parser validates
        }
        let profile = BrowserProfile(kind: kind,
                                     profileName: source.deletingPathExtension().lastPathComponent,
                                     bookmarkFileURL: source, readable: true)
        return try BrowserImporter.importProfile(profile, into: directory)
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
