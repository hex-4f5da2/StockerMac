import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift process-app-icon.swift <input.png> <output.png>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: inputURL) else { fatalError("Unable to load input image") }

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("Unable to create bitmap") }

bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Unable to create graphics context") }
NSGraphicsContext.current = context
context.imageInterpolation = .high

let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
rect.fill()
NSBezierPath(roundedRect: rect, xRadius: 150, yRadius: 150).addClip()
source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode output image")
}
try data.write(to: outputURL, options: .atomic)
