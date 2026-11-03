// Embertrail art pipeline: turns the generated sprite sheets into clean, feet-anchored sprites at game size.
//
// The sheets are draft art: roughly gridded, not evenly spaced, sometimes with a stray pixel from a neighbour.
// So instead of slicing a fixed grid, every opaque blob is found (alpha >= 128), assigned to the grid cell
// holding its centre, and each cell's blobs become one frame. Frames are then scaled per family/stage with one
// shared factor (so poses keep their relative size) and anchored at the feet (bottom centre).
import Foundation
import CoreGraphics
import ImageIO

/// Device pixels per logical game pixel that sprites are prepared at (scale 2 x Retina 2).
let artRes: CGFloat = 4

struct Sprite {
    let image: CGImage
    let w: Double, h: Double          // logical px
    let anchorX: Double                // logical px from the left edge to the feet centre
    let mask: [Bool]                   // opaque map at logical resolution, row 0 at the bottom
    let mw: Int, mh: Int
}

struct Cut { let image: CGImage; let w: Int; let h: Int }   // trimmed source frame (source px)

enum ArtError: Error { case missing(String) }

func loadSheet(_ dir: URL, _ name: String) throws -> CGImage {
    let url = dir.appendingPathComponent(name + ".png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw ArtError.missing(url.path) }
    return img
}

/// Cuts a roughly gridded sheet into frames: [row][column].
func cutSheet(_ img: CGImage, cols: Int, rows: Int, minBlob: Int = 24) -> [[Cut?]] {
    let W = img.width, H = img.height
    var px = [UInt8](repeating: 0, count: W * H * 4)
    px.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    // Connected components on alpha >= 128 (4-neighbour), memory row 0 = top.
    var label = [Int32](repeating: -1, count: W * H)
    struct Blob { var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0, n = 0, sx = 0, sy = 0 }
    var blobs: [Blob] = []
    var stack: [Int] = []
    for start in 0..<(W * H) where px[start * 4 + 3] >= 128 && label[start] < 0 {
        let id = Int32(blobs.count)
        var b = Blob()
        label[start] = id; stack.append(start)
        while let i = stack.popLast() {
            let x = i % W, y = i / W
            b.x0 = min(b.x0, x); b.y0 = min(b.y0, y); b.x1 = max(b.x1, x); b.y1 = max(b.y1, y)
            b.n += 1; b.sx += x; b.sy += y
            for j in [x > 0 ? i - 1 : -1, x < W - 1 ? i + 1 : -1, y > 0 ? i - W : -1, y < H - 1 ? i + W : -1]
            where j >= 0 && label[j] < 0 && px[j * 4 + 3] >= 128 {
                label[j] = id; stack.append(j)
            }
        }
        blobs.append(b)
    }
    // Rows are measured, not assumed: generated sheets drift, so find the horizontal bands that actually hold
    // pixels (separated by empty lines) and merge the closest bands until there is one per row.
    let kept = blobs.indices.filter { blobs[$0].n >= minBlob }
    var used = [Bool](repeating: false, count: H)
    for i in kept { for y in blobs[i].y0...blobs[i].y1 { used[y] = true } }
    var bands: [(lo: Int, hi: Int)] = []
    var y = 0
    while y < H {
        if used[y] { let lo = y; while y < H && used[y] { y += 1 }; bands.append((lo, y - 1)) } else { y += 1 }
    }
    while bands.count > rows {
        var best = 1
        for k in 1..<bands.count where bands[k].lo - bands[k - 1].hi < bands[best].lo - bands[best - 1].hi { best = k }
        bands[best - 1] = (bands[best - 1].lo, bands[best].hi)
        bands.remove(at: best)
    }
    let uniform = bands.count != rows            // rows touch each other: fall back to the even grid
    let cw = Double(W) / Double(cols), ch = Double(H) / Double(rows)
    var cells = [[[Int]]](repeating: [[Int]](repeating: [], count: cols), count: rows)
    for i in kept {
        let b = blobs[i]
        let c = min(cols - 1, Int(Double(b.sx / b.n) / cw))
        let r = uniform ? min(rows - 1, Int(Double(b.sy / b.n) / ch))
                        : bands.firstIndex { b.y0 >= $0.lo && b.y1 <= $0.hi } ?? 0
        cells[r][c].append(i)
    }
    return cells.map { row in row.map { ids -> Cut? in
        guard !ids.isEmpty else { return nil }
        let x0 = ids.map { blobs[$0].x0 }.min()!, y0 = ids.map { blobs[$0].y0 }.min()!
        let x1 = ids.map { blobs[$0].x1 }.max()!, y1 = ids.map { blobs[$0].y1 }.max()!
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        let keep = Set(ids.map(Int32.init))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y0 + y) * W + (x0 + x)
            guard keep.contains(label[i]) else { continue }           // only this cell's blobs: no neighbours
            let o = (y * w + x) * 4
            out[o] = px[i * 4]; out[o + 1] = px[i * 4 + 1]; out[o + 2] = px[i * 4 + 2]; out[o + 3] = 255
        } }
        let image = out.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        return Cut(image: image, w: w, h: h)
    } }
}

/// Scales a cut by `k` (source px -> logical px) and renders it at `artRes`, anchored at the bottom centre.
func makeSprite(_ c: Cut, k: Double) -> Sprite {
    let lw = max(1, Double(c.w) * k), lh = max(1, Double(c.h) * k)
    let W = max(1, Int((lw * Double(artRes)).rounded())), H = max(1, Int((lh * Double(artRes)).rounded()))
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(c.image, in: CGRect(x: 0, y: 0, width: W, height: H))
    let img = ctx.makeImage()!
    // Logical-resolution opaque mask for collisions with scenery-sized things (row 0 = bottom).
    let mw = max(1, Int(lw.rounded())), mh = max(1, Int(lh.rounded()))
    var small = [UInt8](repeating: 0, count: mw * mh * 4)
    small.withUnsafeMutableBytes { p in
        let m = CGContext(data: p.baseAddress, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        m.interpolationQuality = .high
        m.draw(c.image, in: CGRect(x: 0, y: 0, width: mw, height: mh))
    }
    var mask = [Bool](repeating: false, count: mw * mh)
    for y in 0..<mh { for x in 0..<mw { mask[y * mw + x] = small[((mh - 1 - y) * mw + x) * 4 + 3] > 110 } }
    return Sprite(image: img, w: Double(W) / Double(artRes), h: Double(H) / Double(artRes), anchorX: Double(W) / Double(artRes) / 2,
                  mask: mask, mw: mw, mh: mh)
}

/// All sprites the game uses. Original-mode art only.
final class Art {
    struct Stage { let idle: [Sprite]; let run: [Sprite]; let jump: [Sprite] }
    struct Family { let id: String; let name: String; let stages: [Stage] }
    /// Starter families that loaded (the ember gecko always; the others if their sheet is present and cuts cleanly).
    let families: [Family]
    var hero: [Stage] { families[0].stages }
    let orb: [Sprite], orbBounce: [Sprite], orbOpen: [Sprite], sparkle: [Sprite]
    let rockSmall: Sprite, boulder: Sprite, spike: Sprite, spikes3: Sprite, crate: Sprite
    let signWater: Sprite, signWarn: Sprite
    let crab: [Sprite], mole: [Sprite]
    let explorerCheer: [Sprite]
    let balloon: [Sprite]
    let gruntIdle: [Sprite], gruntRun: [Sprite], gruntDown: Sprite   // moth-gang grunt; knocked flat
    let smallOrb: [Sprite]             // thrown capture orbs (smaller than the collectible ones)
    let swirl: [CGImage]               // cartoon dizzy-eyes swirl, 4 rotation frames
    let ground: [CGImage]              // per biome: a thin top strip (16 x 4 logical) that tiles
    let soil: [CGImage]                // per biome: fill under the surface (16 x 16)
    let water: [CGImage], splash: [Sprite]
    let parallax: [[Sprite]]           // [biome][far, mid, near]
    let biomeDeco: [Sprite]            // flowers, crystals, ember rocks

    static let heroHeights: [Double] = [16, 20, 24]

    init(dir: URL) throws {
        func row(_ r: Int, in sheet: [[Cut?]]) -> [Cut] { sheet[r].compactMap { $0 } }
        func family(_ file: String) throws -> [Stage]? {
            let sheet = cutSheet(try loadSheet(dir, file), cols: 6, rows: 9)
            guard sheet.allSatisfy({ $0.compactMap { $0 }.count >= 2 }) else { return nil }   // a draft that didn't cut cleanly
            return (0..<3).map { s in
                let idle = row(s * 3, in: sheet), run = row(s * 3 + 1, in: sheet), jump = row(s * 3 + 2, in: sheet)
                // One scale per stage from the idle pose, so running/jumping poses keep their true size relative to it.
                let k = Art.heroHeights[s] / Double(idle.map(\.h).max()!)
                return Stage(idle: idle.map { makeSprite($0, k: k) }, run: run.map { makeSprite($0, k: k) }, jump: jump.map { makeSprite($0, k: k) })
            }
        }
        var fams = [Family(id: "ember", name: "Ember Gecko", stages: try family("ember-gecko-evolutions")!)]
        for (id, file, name) in [("thistle", "thistle-hedgehog-evolutions", "Thistle Hedgehog"), ("ripple", "ripple-newt-evolutions", "Ripple Newt")] {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(file + ".png").path), let st = try family(file) {
                fams.append(Family(id: id, name: name, stages: st))
            }
        }
        families = fams

        let objs = cutSheet(try loadSheet(dir, "orbs-obstacles-signs"), cols: 6, rows: 6, minBlob: 6)
        let orbK = 9 / Double(row(0, in: objs).map(\.h).max()!)
        orb = row(0, in: objs).map { makeSprite($0, k: orbK) }
        orbBounce = row(1, in: objs).map { makeSprite($0, k: orbK) }
        orbOpen = row(2, in: objs).map { makeSprite($0, k: orbK) }
        sparkle = row(3, in: objs).map { makeSprite($0, k: orbK) }
        smallOrb = row(0, in: objs).map { makeSprite($0, k: orbK * 6 / 9) }
        let props = objs[4]
        func sized(_ c: Cut?, h: Double) -> Sprite { let c = c!; return makeSprite(c, k: h / Double(c.h)) }
        rockSmall = sized(props[0], h: 6); boulder = sized(props[1], h: 8)
        spike = sized(props[3], h: 8); spikes3 = sized(props[4], h: 8); crate = sized(props[5], h: 9)
        signWater = sized(objs[5][1], h: 13); signWarn = sized(objs[5][2], h: 13)

        let critters = cutSheet(try loadSheet(dir, "creatures-and-explorer"), cols: 6, rows: 6)
        let crabK = 7 / Double(row(3, in: critters).map(\.h).max()!)
        crab = row(3, in: critters).map { makeSprite($0, k: crabK) }
        let moleK = 8 / Double(row(1, in: critters).map(\.h).max()!)
        mole = row(1, in: critters).map { makeSprite($0, k: moleK) }
        let expK = 18 / Double(row(5, in: critters).map(\.h).max()!)
        explorerCheer = row(5, in: critters).map { makeSprite($0, k: expK) }

        let gang = cutSheet(try loadSheet(dir, "moth-balloon-gang"), cols: 6, rows: 6)
        let balK = 34 / Double(row(0, in: gang).map(\.h).max()!)
        balloon = row(0, in: gang).map { makeSprite($0, k: balK) }
        let gK = 12 / Double(row(3, in: gang).map(\.h).max()!)
        gruntIdle = row(3, in: gang).map { makeSprite($0, k: gK) }
        gruntRun = row(4, in: gang).map { makeSprite($0, k: gK) }
        gruntDown = makeSprite(rotateCut(row(3, in: gang)[0]), k: gK)
        swirl = (0..<4).map { swirlImage(phase: Double($0) / 4) }

        let terrain = cutSheet(try loadSheet(dir, "terrain-water-lava"), cols: 6, rows: 6, minBlob: 6)
        func tile(_ c0: Cut, w: Double, h: Double, top: Double) -> CGImage {
            // Drop the tile's drawn left/right outline so it repeats without seams, scale it to w logical px
            // wide, and keep only the top `h` logical rows.
            let inset = Int(Double(c0.w) * 0.09)
            let c = Cut(image: c0.image.cropping(to: CGRect(x: inset, y: 0, width: c0.w - 2 * inset, height: c0.h))!, w: c0.w - 2 * inset, h: c0.h)
            let k = w / Double(c.w)
            let full = makeSprite(c, k: k)
            let cropH = Int((h * Double(artRes)).rounded())
            return full.image.cropping(to: CGRect(x: 0, y: Int(top * Double(artRes)), width: full.image.width, height: cropH))!
        }
        ground = (0..<3).map { b in tile(terrain[b][1]!, w: 16, h: 4, top: 0) }
        soil = (0..<3).map { b in tile(terrain[b][4]!, w: 16, h: 4, top: 4) }
        let waterK = 16 / Double(terrain[3][0]!.w)
        water = row(3, in: terrain).map { makeSprite($0, k: waterK).image }
        splash = row(4, in: terrain).map { makeSprite($0, k: 10 / Double(row(4, in: terrain).map(\.h).max()!)) }
        biomeDeco = (0..<3).map { b in sized(terrain[b][5], h: 6) }

        let para = cutSheet(try loadSheet(dir, "biome-parallax"), cols: 3, rows: 3)
        parallax = (0..<3).map { b in
            [sized(para[b][0], h: 14), sized(para[b][1], h: 12), sized(para[b][2], h: 6)]
        }
    }
}

/// Turns a standing sprite onto its back (90 degrees), for the knocked-over grunt.
func rotateCut(_ c: Cut) -> Cut {
    let ctx = CGContext(data: nil, width: c.h, height: c.w, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: CGFloat(c.h), y: 0)
    ctx.rotate(by: .pi / 2)
    ctx.draw(c.image, in: CGRect(x: 0, y: 0, width: c.w, height: c.h))
    return Cut(image: ctx.makeImage()!, w: c.h, h: c.w)
}

/// A little spiral (6 x 6 logical px) in the art's outline style: the classic "dizzy eyes".
func swirlImage(phase: Double) -> CGImage {
    let n = Int(6 * artRes)
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGFloat(n) / 2
    let path = CGMutablePath()
    for i in 0...60 {
        let t = Double(i) / 60, a = (t * 2.2 + phase) * 2 * .pi, r = CGFloat(0.5 + t * 0.42) * c
        let p = CGPoint(x: c + cos(a) * r, y: c + sin(a) * r)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    ctx.setLineCap(.round)
    ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 0.09, green: 0.1, blue: 0.2, alpha: 1)); ctx.setLineWidth(artRes * 1.1); ctx.strokePath()
    ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 1, green: 0.92, blue: 0.55, alpha: 1)); ctx.setLineWidth(artRes * 0.5); ctx.strokePath()
    return ctx.makeImage()!
}
