// Removes the plain white background from a generated sprite sheet (JPG) and saves a transparent PNG.
// Flood-fills from the image edges through near-white pixels, so whites *inside* sprites (eyes) survive.
//   swift Tools/keyout.swift in.jpg out.png
import AppKit
let a = CommandLine.arguments
let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
let W = img.width, H = img.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
func light(_ i: Int) -> Bool { px[i * 4] > 222 && px[i * 4 + 1] > 222 && px[i * 4 + 2] > 222 }   // JPEG-noisy white
var bg = [Bool](repeating: false, count: W * H)
var stack: [Int] = []
for x in 0..<W { stack.append(x); stack.append((H - 1) * W + x) }
for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
while let i = stack.popLast() {
    if bg[i] || !light(i) { continue }
    bg[i] = true
    let x = i % W, y = i / W
    if x > 0 { stack.append(i - 1) }; if x < W - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - W) }; if y < H - 1 { stack.append(i + W) }
}
// Soft JPEG fringe: light, low-saturation pixels touching the background go too.
var fringe: [Int] = []
for i in 0..<(W * H) where !bg[i] {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    guard min(r, g, b) > 190 && max(r, g, b) - min(r, g, b) < 30 else { continue }
    let x = i % W, y = i / W
    if (x > 0 && bg[i - 1]) || (x < W - 1 && bg[i + 1]) || (y > 0 && bg[i - W]) || (y < H - 1 && bg[i + W]) { fringe.append(i) }
}
for i in fringe { bg[i] = true }
for i in 0..<(W * H) where bg[i] { px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0 }
let out = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, out, nil); CGImageDestinationFinalize(d)
print("wrote \(a[2]): \(bg.filter { $0 }.count * 100 / (W * H))% transparent")
