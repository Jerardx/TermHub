import AppKit
import UniformTypeIdentifiers

// Usage: swift trim-icon.swift <src.png> <dst.png>
// Trims the baked "transparency checkerboard" / shadow margin around a squircle
// app-icon artwork and applies a real transparent rounded-rect (squircle) mask.

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: trim-icon.swift <src> <dst>") }

let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
guard let isrc = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { fatalError("bad image") }

let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// Find bounding box of "colorful" pixels (the squircle body). The checkerboard
// and drop shadow are near-gray, so saturation cleanly separates them.
func saturated(_ i: Int) -> Bool {
    let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
    let sat = mx > 0 ? (mx - mn) / mx : 0
    return sat > 0.20
}

var minX = w, minY = h, maxX = -1, maxY = -1 // y in bottom-left origin (buffer space)
for y in 0..<h {
    for x in 0..<w {
        if saturated((y * w + x) * 4) {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
guard maxX >= 0 else { fatalError("no content found") }

// Square the bbox (centered) and convert to top-left origin for CGImage cropping.
let bw = maxX - minX + 1, bh = maxY - minY + 1
let side = max(bw, bh)
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
var x0 = cx - side / 2, y0b = cy - side / 2
x0 = max(0, min(x0, w - side))
y0b = max(0, min(y0b, h - side))
let topLeftY = h - (y0b + side) // flip to top-left origin
let cropRect = CGRect(x: x0, y: max(0, topLeftY), width: side, height: side)
guard let cropped = cg.cropping(to: cropRect) else { fatalError("crop failed") }

// Render into a square output with small transparent padding + squircle mask.
let out = side
let pad = CGFloat(out) * 0.04
let rect = CGRect(x: pad, y: pad, width: CGFloat(out) - 2 * pad, height: CGFloat(out) - 2 * pad)
guard let octx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8,
                           bytesPerRow: 0, space: cs,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
octx.clear(CGRect(x: 0, y: 0, width: out, height: out))
let radius = rect.width * 0.2237 // Apple squircle corner ratio
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
octx.addPath(path)
octx.clip()
octx.draw(cropped, in: rect)

guard let result = octx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { fatalError("encode failed") }
CGImageDestinationAddImage(dest, result, nil)
CGImageDestinationFinalize(dest)

print("trimmed \(w)x\(h) -> bbox \(bw)x\(bh) -> output \(out)x\(out) (squircle, transparent corners)")
