import AppKit
import SwiftUI

// compose <art.png> <out.png>: 1024 canvas, 824 continuous-corner tile, macOS icon grid shadow
let args = CommandLine.arguments
let art = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let size = 1024, tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = Path(roundedRect: tile, cornerRadius: 185, style: .continuous).cgPath
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(shape); ctx.clip(); ctx.draw(art, in: tile); ctx.restoreGState()
ctx.addPath(shape); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(3); ctx.strokePath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
