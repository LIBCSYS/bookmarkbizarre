// render_icon.swift — AppIcon.svg → every PNG the macOS AppIcon set needs,
// plus Contents.json. Uses AppKit's built-in SVG renderer (CoreSVG), so the
// icon rebuilds on any Mac with Xcode and no Homebrew/Python dependencies.
//
//   design/render_icon.sh            (compiles + runs this)
//
// Each size is rasterized straight from the vector — never downscaled from a
// 1024 PNG — so the 16px and 32px slots stay crisp instead of mushy.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render_icon <AppIcon.svg> <AppIcon.appiconset dir>\n".data(using: .utf8)!)
    exit(2)
}
let svgURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)

guard let svg = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write("cannot load \(svgURL.path)\n".data(using: .utf8)!)
    exit(1)
}

// macOS slots: 16/32/128/256/512 points, each at 1x and 2x.
let slots: [(points: Int, scale: Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 1), ($0, 2)] }

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)   // 1 point = 1 pixel in this context
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
             from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
var cache: [Int: Data] = [:]          // 32@1x == 16@2x etc. — render each pixel size once
for slot in slots {
    let px = slot.points * slot.scale
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    let png = cache[px] ?? render(pixels: px)
    cache[px] = png
    try png.write(to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(slot.points)x\(slot.points)",
                   "scale": "\(slot.scale)x", "filename": name])
    print("\(name)  \(px)px")
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
