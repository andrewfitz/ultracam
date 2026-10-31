import AppKit
let names = CommandLine.arguments.dropFirst(2)
let out = CommandLine.arguments[1]
var missing: [String] = []
for name in names {
  guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
    let image = base.withSymbolConfiguration(.init(pointSize: 48, weight: .medium)) else { missing.append(name); continue }
  let size = image.size
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(origin: .zero, size: size))
  NSColor.white.set()
  NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
  NSGraphicsContext.restoreGraphicsState()
  try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("missing:", missing)
