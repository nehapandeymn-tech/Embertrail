// Embertrail: a tiny endless runner in a transparent strip just above the macOS Dock.
// Rules live in Game.swift, sprites in Art.swift; this file draws, hosts the window and runs the tools.
import Cocoa

let px: CGFloat = 2                       // points per logical px
let stripH = 50.0                          // logical px: y -4 ... 46
let bandDepth = T.bandDepth

func artDir() -> URL {
    let bundled = Bundle.main.resourceURL!.appendingPathComponent("Art")
    if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Art")
}

// MARK: - Settings

enum Prefs {
    static let d = UserDefaults.standard
    static var best: Int { get { d.integer(forKey: "best.v1.original") } set { d.set(newValue, forKey: "best.v1.original") } }
    static var width: Double { get { d.object(forKey: "width") as? Double ?? 720 } set { d.set(newValue, forKey: "width") } }
    static var offset: Double { get { d.double(forKey: "offset") } set { d.set(newValue, forKey: "offset") } }
    static var scenery: Double { get { d.object(forKey: "scenery") as? Double ?? 1 } set { d.set(newValue, forKey: "scenery") } }
    static var reduceMotion: Bool { get { d.bool(forKey: "reduceMotion") } set { d.set(newValue, forKey: "reduceMotion") } }
    static var display: Int { get { d.integer(forKey: "display") } set { d.set(newValue, forKey: "display") } }
    static var hidden: Bool { get { d.bool(forKey: "hidden") } set { d.set(newValue, forKey: "hidden") } }
    static var starter: String? { get { d.string(forKey: "starter") } set { d.set(newValue, forKey: "starter") } }
}

// MARK: - Visual effects (decorative; never touch game truth)

struct Effect { enum Kind { case sparkle, splash, burst, text(String) }; let kind: Kind; let x: Double; let y: Double; var t = 0.0; let life: Double }

// MARK: - Scene (Core Animation layer tree)

final class Scene {
    let art: Art
    let root = CALayer()
    private let world = CALayer()
    private var pools: [String: [CALayer]] = [:]
    private var used: [String: Int] = [:]
    private let heroL = CALayer(), markerL = CALayer(), hudL = CALayer(), msgL = CALayer(), helpL = CALayer()
    private let buttonL = CALayer(), buttonText = CALayer(), changeText = CALayer(), titleL = CALayer()
    /// Clickable areas in view points ("play", "change", "pick0"...). The app makes only these clickable.
    private(set) var buttons: [String: CGRect] = [:]
    var hot: String? = nil
    var starter = 0                     // index into art.families
    var picking = false                 // showing "Choose your starter" 
    private var textCache: [String: CGImage] = [:]
    private(set) var size = CGSize.zero, backing: CGFloat = 2
    var effects: [Effect] = []
    var reduceMotion = false
    var scenery = 1.0
    private var cheerUntil = -1.0

    init(art: Art) {
        self.art = art
        root.masksToBounds = true
        root.addSublayer(world)
        for l in [heroL, markerL, hudL, msgL, helpL, buttonL, buttonText, changeText, titleL] { pix(l) }
        buttonL.cornerRadius = 9
        buttonL.borderWidth = 1
        markerL.cornerRadius = 2
        markerL.zPosition = 4                                   // above the ground tiles it marks
        markerL.backgroundColor = CGColor(red: 1, green: 0.32, blue: 0.24, alpha: 1)
        markerL.borderColor = CGColor(red: 1, green: 0.95, blue: 0.85, alpha: 0.9); markerL.borderWidth = 1
    }

    private func pix(_ l: CALayer) { l.magnificationFilter = .nearest; l.minificationFilter = .linear; l.contentsGravity = .resize; l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(), "hidden": NSNull()] }

    func layout(size: CGSize, backing: CGFloat) {
        guard size != self.size || backing != self.backing else { return }
        self.size = size; self.backing = backing
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size); world.frame = root.bounds
        textCache = [:]
        CATransaction.commit()
    }

    private func pooled(_ key: String) -> CALayer {
        let i = used[key, default: 0]
        var pool = pools[key, default: []]
        if i == pool.count { let l = CALayer(); pix(l); pool.append(l); pools[key] = pool }
        used[key] = i + 1
        let l = pool[i]
        if l.superlayer == nil { world.addSublayer(l) }
        l.isHidden = false
        return l
    }
    private func endPools() {
        for (k, pool) in pools { for i in used[k, default: 0]..<pool.count { pool[i].isHidden = true } }
        used = [:]
    }

    /// Logical rect (x, y-up from the ground surface) -> layer frame in points.
    private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        let s = { (v: Double) -> CGFloat in (CGFloat(v) * px * self.backing).rounded() / self.backing }
        return CGRect(x: s(x), y: s(y + bandDepth), width: s(x + w) - s(x), height: s(y + bandDepth + h) - s(y + bandDepth))
    }
    private func put(_ l: CALayer, _ img: CGImage, _ r: CGRect) { if (l.contents as AnyObject?) !== img { l.contents = img }; l.frame = r }
    private func sprite(_ key: String, _ s: Sprite, feetX: Double, y: Double, opacity: Float = 1) {
        let l = pooled(key)
        put(l, s.image, frame(feetX - s.anchorX, y, s.w, s.h))
        l.opacity = opacity
    }

    func consume(_ events: [Event], _ g: Game) {
        for e in events {
            switch e {
            case .orb(let id):
                if let t = g.things.first(where: { $0.id == id }) { effects.append(Effect(kind: .sparkle, x: t.x + t.w / 2, y: t.y, life: 0.45)) }
            case .died(let water):
                if water { effects.append(Effect(kind: .splash, x: T.heroX, y: -1, life: 0.6)) }
            case .evolved:
                effects.append(Effect(kind: .burst, x: T.heroX, y: 4, life: 0.5)); cheerUntil = g.clock + 1.6
            case .defeated(let id):
                if let t = g.things.first(where: { $0.id == id }) {
                    effects.append(Effect(kind: .sparkle, x: t.x + t.w / 2, y: 6, life: 0.4))
                    effects.append(Effect(kind: .text("+25"), x: t.x + t.w / 2, y: 14, life: 0.9))
                }
            case .smashLanded(let id):
                if let t = g.things.first(where: { $0.id == id }) { effects.append(Effect(kind: .sparkle, x: t.x + 3, y: 0, life: 0.3)) }
            default: break
            }
        }
    }

    func update(_ g: Game, dt: Double, help: String) {
        guard size.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let clock = g.clock
        let moving = !reduceMotion

        // Parallax biome: far/mid/near strips with transparent gaps, crossfading during an evolution.
        var biomes: [(Int, Float)] = [(g.stage, 1)]
        if g.phase == .evolving, let p = g.pendingStage {
            let k = Float(min(1, g.evolveT / T.evolveFreeze))
            biomes = g.stage == p ? [(p - 1, 1 - k), (p, k)] : [(g.stage, 1 - k), (p, k)]
        }
        let factors = [0.15, 0.35, 0.6], baseOpacity: [Float] = [0.3, 0.38, 0.5], gaps = [40.0, 70.0, 90.0]
        if scenery > 0 {
            for (b, a) in biomes {
                for layer in 0..<3 {
                    let s = art.parallax[b][layer]
                    let period = s.w + gaps[layer]
                    let off = (moving ? g.distance * factors[layer] : 0).truncatingRemainder(dividingBy: period)
                    var x = -off + Double(layer) * 23
                    while x < g.worldW + period {
                        sprite("para\(layer)", s, feetX: x + s.anchorX, y: 0, opacity: baseOpacity[layer] * a * Float(scenery))
                        x += period
                    }
                }
            }
        }

        // Ground: 16 px tiles cut around the pits (real gaps), water showing inside them.
        let pits = g.things.filter { $0.kind == .pit }.map { ($0.x, $0.x + $0.w) }
        let groundImg = art.ground[g.stage]
        var tx = -g.distance.truncatingRemainder(dividingBy: 16)
        while tx < g.worldW {
            var pieces = [(tx, tx + 16)]
            for (a, b) in pits { pieces = pieces.flatMap { (p0, p1) -> [(Double, Double)] in
                if b <= p0 || a >= p1 { return [(p0, p1)] }
                return [(p0, max(p0, a)), (min(p1, b), p1)].filter { $0.1 - $0.0 > 0.01 }
            } }
            for (a, b) in pieces {
                let l = pooled("ground")
                if (l.contents as AnyObject?) !== groundImg { l.contents = groundImg }
                l.contentsRect = CGRect(x: (a - tx) / 16, y: 0, width: (b - a) / 16, height: 1)
                l.frame = frame(a, -bandDepth, b - a, bandDepth)
            }
            tx += 16
        }
        let waterFrame = art.water[moving ? Int(clock * 5) % art.water.count : 0]
        for (a, b) in pits {
            var x = a
            while x < b {
                let w = min(16, b - x)
                let l = pooled("water")
                if (l.contents as AnyObject?) !== waterFrame { l.contents = waterFrame }
                l.contentsRect = CGRect(x: 0, y: 0, width: w / 16, height: 1)
                let h = Double(waterFrame.height) / Double(artRes)
                l.frame = frame(x, -0.6 - h + 2, w, h)
                x += 16
            }
        }

        // Things.
        for t in g.things where !t.gone {
            let cx = t.x + t.w / 2
            switch t.kind {
            case .rock, .fallingRock: sprite("thing", art.rockSmall, feetX: cx, y: t.y)
            case .spike: sprite("thing", art.spike, feetX: cx, y: 0)
            case .crate: sprite("thing", art.crate, feetX: cx, y: 0)
            case .boulder: sprite("thing", art.boulder, feetX: cx, y: 0)
            case .crab: sprite("thing", art.crab[moving ? Int(t.t * 10) % art.crab.count : 0], feetX: cx, y: 0)
            case .mole: sprite("thing", art.mole[moving ? Int(t.t * 9) % art.mole.count : 0], feetX: cx, y: 0)
            case .sign: sprite("thing", art.signWater, feetX: cx, y: 0)
            case .orb:
                let bob = moving ? (sin(t.t * 5) * 0.8).rounded() : 0
                sprite("thing", art.orb[moving ? Int(t.t * 8) % art.orb.count : 0], feetX: cx, y: t.y + bob)
            case .pit: break
            case .grunt:
                let member = art.gangMembers[t.id % art.gangMembers.count]
                sprite("thing", member.run[moving ? Int(t.t * 10) % member.run.count : 0], feetX: cx, y: 0)
            case .gruntDown:
                // Knocked flat with swirly eyes, spinning.
                let down = art.gangMembers[t.id % art.gangMembers.count].down
                sprite("thing", down, feetX: cx, y: 0)
                let l = pooled("thing")
                let sw = art.swirl[moving ? Int(t.t * 12) % art.swirl.count : 0]
                put(l, sw, frame(t.x + t.w / 2 + down.w / 2 - 6.5, 1.5, 6, 6))
            case .thrownOrb, .capOrb:
                sprite("thing", art.smallOrb[moving ? Int(t.t * 14) % art.smallOrb.count : 0], feetX: cx, y: t.y)
            }
        }

        // Balloon gang and its drop telegraph.
        markerL.isHidden = true
        if let b = g.balloon {
            let s = art.balloon[moving ? Int(clock * 3) % art.balloon.count : 0]
            let bob = moving ? sin(clock * 2) * 0.6 : 0
            sprite("balloon", s, feetX: b.x, y: b.y + bob)
            if b.stage == .telegraph {
                if markerL.superlayer == nil { root.insertSublayer(markerL, above: world) }   // over the ground it marks
                markerL.isHidden = false
                markerL.frame = frame(b.targetX - 8, -2, 16, 4)            // where the rock will land
                markerL.cornerRadius = 2 * px
                markerL.opacity = reduceMotion ? 1 : Float(0.9 + 0.1 * sin(b.t * 14))
                sprite("fx", art.sparkle[1], feetX: b.targetX, y: 3, opacity: reduceMotion ? 1 : Float(0.6 + 0.4 * sin(b.t * 14)))
            }
        }

        // Explorer cheers from the far right after an evolution (decorative).
        if clock < cheerUntil, g.phase != .ready {
            sprite("cheer", art.explorerCheer[Int(clock * 6) % art.explorerCheer.count], feetX: g.worldW - 22, y: 0, opacity: 0.95)
        }

        // Hero.
        let st = art.families[min(starter, art.families.count - 1)].stages[g.stage]
        func pose(_ a: [Sprite], _ i: Int) -> Sprite { a[min(i, a.count - 1)] }
        var hs: Sprite
        switch g.phase {
        case .ready, .over: hs = st.idle[moving ? Int(clock * 4) % st.idle.count : 0]
        default:
            if g.onGround {
                hs = g.sinceLand < 0.08 ? pose(st.jump, 5) : st.run[moving && g.phase == .running ? Int(g.distance / 6) % st.run.count : 0]
            } else if g.sinceJump < 0.06 { hs = pose(st.jump, 0) }
            else if g.vy > 70 { hs = pose(st.jump, 1) } else if g.vy > 20 { hs = pose(st.jump, 2) }
            else if g.vy > -40 { hs = pose(st.jump, 3) } else { hs = pose(st.jump, 4) }
        }
        if heroL.superlayer == nil { world.addSublayer(heroL) }
        heroL.zPosition = 5
        put(heroL, hs.image, frame(T.heroX - hs.anchorX, g.y, hs.w, hs.h))
        heroL.opacity = g.phase == .dying && moving && Int(g.dyingT * 12) % 2 == 1 ? 0.25 : 1
        heroL.isHidden = (picking && g.phase == .ready) || (g.phase == .dying && g.y < -6) || ((g.phase == .dying || g.phase == .over) && g.captured && g.dyingT > 0.2)
        if g.captured && (g.phase == .dying || g.phase == .over) {
            // The capture orb pops open, snaps shut around the starter, then wobbles three times.
            let k = g.dyingT
            let f: Sprite
            if k < 0.45 { f = art.orbOpen[max(0, min(art.orbOpen.count - 1, art.orbOpen.count - 1 - Int(k / 0.45 * Double(art.orbOpen.count))))] }
            else if k < 1.45 && moving { f = art.orbBounce[Int((k - 0.45) * 9) % art.orbBounce.count] }
            else { f = art.orb[0] }
            let wob = k >= 0.45 && k < 1.45 && moving ? sin((k - 0.45) * 3 * 2 * .pi) * 1.5 : 0
            sprite("fx", f, feetX: T.heroX + wob, y: 0)
        }

        // Effects.
        for i in effects.indices { effects[i].t += dt }
        effects.removeAll { $0.t >= $0.life }
        for e in effects {
            let k = e.t / e.life
            switch e.kind {
            case .sparkle:
                let f = art.sparkle[min(art.sparkle.count - 1, Int(k * Double(art.sparkle.count)))]
                sprite("fx", f, feetX: e.x, y: e.y + 1)
            case .splash:
                let f = art.splash[min(art.splash.count - 1, Int(k * Double(art.splash.count)))]
                sprite("fx", f, feetX: e.x, y: -bandDepth + 1)
            case .text(let str):
                let l = pooled("fxText")
                let img = cachedText(str)
                put(l, img, CGRect(x: CGFloat(e.x) * px - CGFloat(img.width) / backing / 2, y: CGFloat(e.y + bandDepth + k * 8) * px,
                                    width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing))
                l.opacity = Float(1 - k)
            case .burst:
                let f = art.sparkle[min(art.sparkle.count - 1, Int(k * Double(art.sparkle.count)))]
                for a in 0..<6 {
                    let ang = Double(a) / 6 * 2 * .pi, r = reduceMotion ? 8 : 4 + 10 * k
                    sprite("fx", f, feetX: e.x + cos(ang) * r, y: e.y + 6 + sin(ang) * r * 0.7)
                }
            }
        }

        // HUD: tiny and out of the play lane (top right). Messages: centred, only when not running.
        let hud = g.phase == .ready ? (g.best > 0 ? "BEST \(g.best)" : "") : "◆ \(g.orbs)   \(String(format: "%05d", g.score))\(g.best > 0 ? "   BEST \(g.best)" : "")"
        setText(hudL, hud, size: 9, leftX: 8, topY: size.height - 4)       // top left: the balloon hovers on the right
        var msg = ""
        switch g.phase {
        case .ready: msg = "EMBERTRAIL"
        case .paused: msg = "PAUSED"
        case .over: msg = "GAME OVER  ·  \(g.score)"
        default: msg = ""
        }
        setText(msgL, msg, size: 11, centerX: size.width / 2, topY: size.height * 0.86, weight: .heavy)
        setText(helpL, g.phase == .running || g.phase == .evolving || g.phase == .dying ? "" : help, size: 8.5,
                centerX: size.width / 2, topY: size.height * 0.86 - 15, alpha: 0.85)

        // Home screen controls: the only clickable things while the game isn't running.
        buttons = [:]
        for l in [buttonL, buttonText, changeText, titleL] where l.superlayer == nil { root.addSublayer(l) }
        let showPicker = picking && g.phase == .ready
        let label: String? = showPicker ? nil : { switch g.phase { case .ready: return "▶  Play"; case .paused: return "▶  Resume"; case .over: return "▶  Play again"; default: return nil } }()
        if let label {
            buttonL.isHidden = false
            setText(buttonText, label, size: 10.5, centerX: size.width / 2, topY: size.height * 0.86 - 31, weight: .heavy)
            let t = buttonText.frame
            let r = CGRect(x: t.midX - max(t.width + 16, 92) / 2, y: t.midY - 11, width: max(t.width + 16, 92), height: 22)
            buttons["play"] = r
            buttonL.frame = r
            let hotPlay = hot == "play"
            buttonL.backgroundColor = hotPlay ? CGColor(red: 1, green: 0.42, blue: 0.32, alpha: 1) : CGColor(red: 0.88, green: 0.33, blue: 0.27, alpha: 0.95)
            buttonL.borderColor = CGColor(red: 1, green: 0.9, blue: 0.75, alpha: hotPlay ? 1 : 0.6)
            if (g.phase == .ready || g.phase == .over) && art.families.count > 1 {
                setText(changeText, "Change starter", size: 9, leftX: r.maxX + 12, topY: r.midY + 7, weight: .bold, alpha: hot == "change" ? 1 : 0.7)
                buttons["change"] = changeText.frame
            } else { changeText.isHidden = true }
        } else {
            buttonL.isHidden = true; buttonText.isHidden = true; changeText.isHidden = true
        }

        // Choose your starter: one card per family, its first form animating, name underneath.
        if showPicker {
            msgL.isHidden = true; helpL.isHidden = true
            setText(titleL, "CHOOSE YOUR STARTER", size: 10, centerX: size.width / 2, topY: size.height - 2, weight: .heavy)
            let n = art.families.count, cw: CGFloat = 124, gap: CGFloat = 12
            let x0 = size.width / 2 - (CGFloat(n) * cw + CGFloat(n - 1) * gap) / 2
            for (i, f) in art.families.enumerated() {
                let r = CGRect(x: x0 + CGFloat(i) * (cw + gap), y: 10, width: cw, height: 70)
                buttons["pick\(i)"] = r
                let isHot = hot == "pick\(i)"
                let card = pooled("card")
                card.contents = nil
                card.frame = r
                card.cornerRadius = 10
                card.backgroundColor = CGColor(red: 0.09, green: 0.1, blue: 0.18, alpha: isHot ? 0.92 : 0.75)
                card.borderWidth = isHot ? 2 : 1
                card.borderColor = isHot ? CGColor(red: 1, green: 0.55, blue: 0.4, alpha: 1) : CGColor(gray: 1, alpha: 0.25)
                card.zPosition = 6
                let sp = f.stages[0].idle[moving ? Int(clock * 4) % f.stages[0].idle.count : 0]
                let l = pooled("cardSprite")
                l.zPosition = 7
                let sw = CGFloat(sp.w) * px * 1.25, sh = CGFloat(sp.h) * px * 1.25
                put(l, sp.image, CGRect(x: (r.midX - sw / 2).rounded(), y: r.minY + 22, width: sw, height: sh))
                let tl = pooled("cardText")
                tl.zPosition = 7
                let img = cachedText(f.name)
                put(tl, img, CGRect(x: (r.midX - CGFloat(img.width) / backing / 2).rounded(), y: r.minY + 4,
                                    width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing))
            }
        } else { titleL.isHidden = true }
        endPools()
    }

    private func cachedText(_ s: String) -> CGImage {
        let key = "fx|\(s)"
        if let c = textCache[key] { return c }
        let i = textImage(s, size: 9, weight: .heavy, alpha: 1, backing: backing); textCache[key] = i; return i
    }

    // Text: system font (the bitmap font in the pack has no metrics yet), white with a dark outline.
    private func setText(_ l: CALayer, _ s: String, size: CGFloat, leftX: CGFloat? = nil, centerX: CGFloat? = nil, topY: CGFloat,
                         weight: NSFont.Weight = .bold, alpha: CGFloat = 1) {
        if l.superlayer == nil { root.addSublayer(l) }
        guard !s.isEmpty else { l.isHidden = true; return }
        l.isHidden = false
        let key = "\(s)|\(size)|\(weight.rawValue)|\(alpha)"
        let img = textCache[key] ?? {
            let i = textImage(s, size: size, weight: weight, alpha: alpha, backing: backing); textCache[key] = i; return i
        }()
        if (l.contents as AnyObject?) !== img { l.contents = img }
        let w = CGFloat(img.width) / backing, h = CGFloat(img.height) / backing
        let x = leftX ?? ((centerX ?? 0) - w / 2)
        l.frame = CGRect(x: x.rounded(), y: (topY - h).rounded(), width: w, height: h)
    }
}

func textImage(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, backing: CGFloat) -> CGImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.85); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha), .kern: size * 0.08,
                                                         .shadow: shadow, .strokeColor: NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.18, alpha: 1), .strokeWidth: -3])
    let b = str.size()
    let W = Int(((b.width + 6) * backing).rounded(.up)), H = Int(((b.height + 4) * backing).rounded(.up))
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: backing, y: backing)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    str.draw(at: NSPoint(x: 3, y: 2))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

// MARK: - Window

final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }      // keys only while the player has explicitly started playing
    override var canBecomeMain: Bool { false }
}

final class StripView: NSView {
    weak var app: AppController?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with e: NSEvent) { app?.key(e) }
    override func mouseDown(with e: NSEvent) { app?.click() }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var art: Art!
    var game = Game()
    var scene: Scene!
    var panel: StripPanel!
    var view: StripView!
    var status: NSStatusItem!
    var link: CADisplayLink?
    var last = 0.0, acc = 0.0
    var placementNote = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        do { art = try Art(dir: artDir()) } catch {
            let a = NSAlert(); a.messageText = "Embertrail couldn't load its artwork"; a.informativeText = "\(error)"; a.runModal()
            NSApp.terminate(nil); return
        }
        game.best = Prefs.best
        scene = Scene(art: art)
        scene.reduceMotion = Prefs.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        scene.scenery = Prefs.scenery
        if let id = Prefs.starter, let i = art.families.firstIndex(where: { $0.id == id }) { scene.starter = i }
        else { scene.picking = art.families.count > 1 }          // first launch: choose your starter

        panel = StripPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: CGFloat(stripH) * px),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating                                   // above windows, below alerts and the Dock
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]   // not over full-screen Spaces
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        view = StripView(frame: panel.contentLayoutRect)
        view.app = self
        view.layer = scene.root; view.wantsLayer = true
        panel.contentView = view

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = menuIcon()
        status.button?.toolTip = "Embertrail"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu

        place()
        if !Prefs.hidden { panel.orderFrontRegardless() }
        startLink()

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.game.pause() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.place() }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.game.pause() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.game.pause() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.place() }   // follow Dock changes
    }

    // Input: only while the strip has keyboard focus, which happens only after Play.
    func key(_ e: NSEvent) {
        switch e.keyCode {
        case 49, 126: if game.phase == .running || game.phase == .evolving { game.press() }       // Space, Up
        case 36, 76:                                                                              // Return, Enter
            if [.ready, .over, .paused].contains(game.phase) { game.press() }
        case 35: if game.phase == .paused { game.resume() } else { game.pause() }                 // P
        case 53: game.pause(); NSApp.deactivate()                                                 // Escape: pause, hand focus back
        default: break
        }
    }
    func click() {
        if game.phase == .running || game.phase == .evolving { game.press(); return }
        let p = view.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        guard let id = scene.buttons.first(where: { $0.value.insetBy(dx: -4, dy: -4).contains(p) })?.key else { return }
        if id == "play" { play() }
        else if id == "change" { game.phase = .ready; scene.picking = true }
        else if id.hasPrefix("pick"), let i = Int(id.dropFirst(4)), i < art.families.count {
            Prefs.starter = art.families[i].id; scene.starter = i; scene.picking = false
            play()
        }
    }

    @objc func play() {
        if Prefs.hidden { toggleHidden() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        scene.picking = false
        if game.phase == .paused { game.resume() } else if game.phase != .running && game.phase != .evolving { game.start() }
    }
    @objc func pauseGame() { game.pause() }
    @objc func restart() { game.start(); play() }

    // Frame loop: fixed 1/120 s steps, at most 8 per frame; a long stall pauses instead of catching up.
    func startLink() {
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common); link = l
    }
    @objc func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        var dt = last == 0 ? 1.0 / 60 : now - last
        last = now
        if dt > 0.25 { game.pause(); dt = 0; acc = 0 }
        acc += dt
        var n = 0
        while acc >= T.step && n < T.maxCatchUp { game.step(); acc -= T.step; n += 1 }
        if n == T.maxCatchUp { acc = 0 }
        if !game.events.isEmpty {
            scene.consume(game.events, game)
            if game.events.contains(where: { if case .died = $0 { return true }; return false }) { Prefs.best = game.best }
            game.events.removeAll()
        }
        // While playing, the whole strip takes clicks (to jump). Otherwise only the Play button does; anywhere
        // else over the strip it fades and clicks go straight through to the windows behind.
        let playing = game.phase == .running || game.phase == .evolving || game.phase == .dying
        let m = NSEvent.mouseLocation, f = panel.frame
        let local = CGPoint(x: m.x - f.minX, y: m.y - f.minY)
        let hot = playing ? nil : scene.buttons.first(where: { $0.value.insetBy(dx: -4, dy: -4).contains(local) })?.key
        let onButton = hot != nil
        let mouseOn = playing || onButton
        if panel.ignoresMouseEvents == mouseOn { panel.ignoresMouseEvents = !mouseOn }
        scene.hot = hot
        setFaded(!playing && !onButton && f.contains(m))
        scene.layout(size: view.bounds.size, backing: panel.backingScaleFactor)
        scene.update(game, dt: dt, help: helpText)
    }
    var helpText: String {
        game.phase == .ready ? "Space jumps   ·   water is deadly for everyone   ·   Esc pauses" : ""
    }

    var faded = false
    func setFaded(_ on: Bool) {
        guard on != faded else { return }
        faded = on
        let target: CGFloat = on ? 0.15 : 1
        if scene.reduceMotion { panel.alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; panel.animator().alphaValue = target }
    }

    // MARK: Placement: just above the Dock's safe area, on the chosen display.

    func screen() -> NSScreen {
        let screens = NSScreen.screens
        let id = Prefs.display
        if id != 0, let s = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == id }) { return s }
        return screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 1 }) ?? NSScreen.main ?? screens[0]
    }

    func place() {
        guard let panel else { return }
        let s = screen()
        let vf = s.visibleFrame, f = s.frame
        let width = min(max(480, CGFloat(Prefs.width)), vf.width)
        let y: CGFloat
        if vf.minY > f.minY + 1 { y = vf.minY + 2 + CGFloat(Prefs.offset); placementNote = "Above the Dock" }
        else if vf.minX > f.minX + 1 || vf.maxX < f.maxX - 1 { y = f.minY + 6 + CGFloat(Prefs.offset); placementNote = "Bottom edge (the Dock is on the side)" }
        else { y = f.minY + 6 + CGFloat(Prefs.offset); placementNote = "Bottom edge (the Dock hides automatically)" }   // keeps the reveal edge free
        let w = (width / px).rounded(.down) * px
        let frame = NSRect(x: (vf.midX - w / 2).rounded(), y: y.rounded(), width: w, height: CGFloat(stripH) * px)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        game.worldW = Double(w / px)
    }

    // MARK: Menu

    func menuIcon() -> NSImage {
        let s = art.hero[0].idle[0]
        let img = NSImage(size: NSSize(width: 18 * s.w / s.h, height: 16), flipped: false) { r in
            NSGraphicsContext.current?.cgContext.interpolationQuality = .high
            NSGraphicsContext.current?.cgContext.draw(s.image, in: r)
            return true
        }
        img.accessibilityDescription = "Embertrail"
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: game.best > 0 ? "Embertrail  ·  best \(game.best)" : "Embertrail", action: nil, keyEquivalent: ""); head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        switch game.phase {
        case .running, .evolving: menu.addItem(item("Pause", #selector(pauseGame)))
        case .paused: menu.addItem(item("Resume", #selector(play)))
        case .over: menu.addItem(item("Play Again", #selector(play)))
        default: menu.addItem(item("Play", #selector(play)))
        }
        if game.phase != .ready { menu.addItem(item("Restart", #selector(restart))) }
        menu.addItem(info("    Space or ↑ jump · Esc pause · Enter start"))
        menu.addItem(info("    Water pits are deadly for every form"))
        menu.addItem(.separator())

        if NSScreen.screens.count > 1 {
            menu.addItem(sub("Display", NSScreen.screens.map { s in
                let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
                return (s.localizedName, "\(id)", id == Prefs.display)
            }, #selector(pickDisplay(_:))))
        }
        if art.families.count > 1 {
            menu.addItem(sub("Starter", art.families.enumerated().map { ($0.element.name, "\($0.offset)", $0.offset == scene.starter) }, #selector(pickStarter(_:))))
        }
        menu.addItem(sub("Width", [("Narrow", "480", Prefs.width == 480), ("Medium", "720", Prefs.width == 720), ("Wide", "1000", Prefs.width == 1000)], #selector(pickWidth(_:))))
        let pos = sub("Position", [("Raise", "2", false), ("Lower", "-2", false), ("Reset", "0", false)], #selector(nudge(_:)))
        pos.submenu?.insertItem(info(placementNote), at: 0)
        menu.addItem(pos)
        menu.addItem(sub("Scenery", [("Full", "1", Prefs.scenery == 1), ("Light", "0.5", Prefs.scenery == 0.5), ("Off", "0", Prefs.scenery == 0)], #selector(pickScenery(_:))))
        let rm = item("Reduce Motion", #selector(toggleReduceMotion)); rm.state = Prefs.reduceMotion ? .on : .off; menu.addItem(rm)
        menu.addItem(.separator())
        menu.addItem(item(Prefs.hidden ? "Show Strip" : "Hide Strip", #selector(toggleHidden)))
        menu.addItem(NSMenuItem(title: "Quit Embertrail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    func item(_ t: String, _ s: Selector) -> NSMenuItem { let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; return i }
    func info(_ t: String) -> NSMenuItem { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    func sub(_ t: String, _ opts: [(String, String, Bool)], _ s: Selector) -> NSMenuItem {
        let p = NSMenuItem(title: t, action: nil, keyEquivalent: ""), m = NSMenu()
        for (name, v, on) in opts { let i = item(name, s); i.representedObject = v; i.state = on ? .on : .off; m.addItem(i) }
        p.submenu = m; return p
    }
    @objc func pickDisplay(_ i: NSMenuItem) { Prefs.display = Int(i.representedObject as! String) ?? 0; place() }
    @objc func pickStarter(_ i: NSMenuItem) {
        guard let n = Int(i.representedObject as! String), n < art.families.count else { return }
        scene.starter = n; Prefs.starter = art.families[n].id; scene.picking = false
    }
    @objc func pickWidth(_ i: NSMenuItem) { Prefs.width = Double(i.representedObject as! String) ?? 720; place() }
    @objc func nudge(_ i: NSMenuItem) { let v = Double(i.representedObject as! String) ?? 0; Prefs.offset = v == 0 ? 0 : max(-20, min(60, Prefs.offset + v)); place() }
    @objc func pickScenery(_ i: NSMenuItem) { Prefs.scenery = Double(i.representedObject as! String) ?? 1; scene.scenery = Prefs.scenery }
    @objc func toggleReduceMotion() { Prefs.reduceMotion.toggle(); scene.reduceMotion = Prefs.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @objc func toggleHidden() {
        Prefs.hidden.toggle()
        if Prefs.hidden { game.pause(); panel.orderOut(nil); link?.isPaused = true } else { place(); panel.orderFrontRegardless(); link?.isPaused = false; last = 0 }
    }
}

// MARK: - Offline tools

func renderFrame(_ scene: Scene, _ g: Game, width: CGFloat, backing b: CGFloat, dt: Double, bg: Bool = true) -> CGImage {
    let size = CGSize(width: width, height: CGFloat(stripH) * px + 40)
    let ctx = CGContext(data: nil, width: Int(size.width * b), height: Int(size.height * b), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: b, y: b)
    if bg {   // a desktop-ish backdrop and a Dock band, so transparency reads in screenshots
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.16, green: 0.2, blue: 0.32, alpha: 1), CGColor(red: 0.3, green: 0.24, blue: 0.38, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.16))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 4, width: size.width - 40, height: 32), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
    }
    ctx.translateBy(x: 0, y: 40)
    scene.layout(size: CGSize(width: width, height: CGFloat(stripH) * px), backing: b)
    scene.update(g, dt: dt, help: g.phase == .ready ? "Space jumps   ·   water is deadly for everyone   ·   Esc pauses" : "")
    ctx.interpolationQuality = .high
    scene.root.render(in: ctx)
    return ctx.makeImage()!
}

func toolArgs(_ args: [String]) -> (String) -> String? { { k in args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } } }

/// Embertrail --snapshot out.png [--seconds 12 --seed 4 --width 720 --phase ready]
func snapshot(_ args: [String]) {
    let arg = toolArgs(args)
    let art = try! Art(dir: artDir())
    let g = Game(seed: UInt64(arg("--seed") ?? "4") ?? 4)
    let width = CGFloat(Double(arg("--width") ?? "720") ?? 720)
    g.worldW = Double(width / px); g.best = Int(arg("--best") ?? "0") ?? 0
    let scene = Scene(art: art)
    scene.starter = Int(arg("--starter") ?? "0") ?? 0
    scene.picking = args.contains("--picker")
    if let h = arg("--hot") { scene.hot = h }
    if arg("--phase") != "ready" {
        g.autopilot = true; g.start()
        let steps = Int((Double(arg("--seconds") ?? "12") ?? 12) / T.step)
        for _ in 0..<steps { g.step(); scene.consume(g.events, g); g.events.removeAll(); scene.effects = scene.effects.map { var e = $0; e.t += T.step; return e }.filter { $0.t < $0.life } }
    }
    let img = renderFrame(scene, g, width: width, backing: 2, dt: 0)
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arg("--snapshot")!) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    print("wrote \(arg("--snapshot")!): phase \(g.phase) stage \(g.stage) score \(g.score) orbs \(g.orbs) t \(String(format: "%.1f", g.active))")
}

/// Embertrail --record out.gif [--from 0 --to 20 --fps 15 --seed 4] — the bot plays, every frame rendered like the app.
func record(_ args: [String]) {
    let arg = toolArgs(args)
    let art = try! Art(dir: artDir())
    let g = Game(seed: UInt64(arg("--seed") ?? "4") ?? 4)
    let width = CGFloat(Double(arg("--width") ?? "720") ?? 720)
    g.worldW = Double(width / px); g.best = Int(arg("--best") ?? "0") ?? 0
    let from = Double(arg("--from") ?? "0") ?? 0, to = Double(arg("--to") ?? "20") ?? 20, fps = Double(arg("--fps") ?? "15") ?? 15
    let scene = Scene(art: art)
    scene.starter = Int(arg("--starter") ?? "0") ?? 0
    g.autopilot = true; g.start()
    var images: [CGImage] = []
    var t = 0.0
    let per = Int((1 / fps / T.step).rounded())
    while t < to {
        for _ in 0..<per { g.step(); scene.consume(g.events, g); g.events.removeAll(); t += T.step }
        if g.phase == .over { break }
        if t >= from { images.append(renderFrame(scene, g, width: width, backing: 1, dt: Double(per) * T.step)) }
        else { scene.update(g, dt: Double(per) * T.step, help: "") }
    }
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arg("--record")!) as CFURL, "com.compuserve.gif" as CFString, images.count, nil)!
    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for i in images { CGImageDestinationAddImage(d, i, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary) }
    print("\(CGImageDestinationFinalize(d) ? "wrote" : "FAILED") \(arg("--record")!): \(images.count) frames, phase \(g.phase), stage \(g.stage), score \(g.score)")
}

// MARK: - Self-test (acceptance checks that don't need a screen)

func selftest() -> Int32 {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } }
    func run(_ g: Game, _ seconds: Double) { for _ in 0..<Int(seconds / T.step) { g.step() } }

    // Art: every sheet cut, hero forms at their heights, adult apex inside the strip.
    let art = try! Art(dir: artDir())
    check(art.families.count == 3, "three starters load (\(art.families.map(\.name)))")
    check(art.families.map(\.id) == ["charmander", "bulbasaur", "squirtle"], "Pokémon starter sheets are active")
    check(art.gangMembers.count == 2 && art.gangMembers.allSatisfy { $0.idle.count == 6 && $0.run.count == 6 }, "Jessie and James animation frames load")
    for member in art.gangMembers {
        check((member.idle + member.run).allSatisfy { $0.h >= 9 && $0.h <= 13 }, "Team Rocket poses retain consistent character size")
    }
    for f in art.families {
        check(f.stages.count == 3 && f.stages.allSatisfy { $0.idle.count == 6 && $0.run.count == 6 && $0.jump.count == 6 }, "\(f.name): 3 x (6 idle, 6 run, 6 jump)")
        for (i, st) in f.stages.enumerated() {
            let tallest = (st.idle + st.run + st.jump).map(\.h).max()!
            check(abs(st.idle.map(\.h).max()! - Art.heroHeights[i]) < 0.6, "\(f.name) stage \(i) idle height")
            let apexTop = T.jumpV * T.jumpV / (2 * T.gravity) + tallest
            check(apexTop <= T.top, "\(f.name) stage \(i) apex top \(apexTop) within \(T.top)")
        }
    }
    check(art.orb.count == 6 && art.sparkle.count == 6 && art.water.count == 6 && art.balloon.count == 6 && art.crab.count == 6, "orb/sparkle/water/balloon/crab frames")

    // Physics: apex and airtime from the brief (19.36 px, 0.44 s).
    let p = Game(seed: 1); p.start(); p.gapLeft = 1e9
    p.press(); var apex = 0.0, air = 0.0
    repeat { p.step(); apex = max(apex, p.y); air += T.step } while !p.onGround && air < 2
    check(abs(apex - 19.36) < 0.3 && abs(air - 0.44) < 0.03, "apex \(apex), airtime \(air)")

    // Jump buffer: one press shortly before landing gives exactly one jump.
    let jb = Game(seed: 1); jb.start(); jb.gapLeft = 1e9
    jb.press(); run(jb, 0.38); jb.events.removeAll(); jb.press(); run(jb, 1.2)
    check(jb.events.filter { if case .jumped = $0 { return true }; return false }.count == 1, "jump buffer: one jump from one press")

    // Coyote: walking off a pit lip and pressing within 70 ms still jumps.
    let cy = Game(seed: 1); cy.start(); cy.gapLeft = 1e9
    cy.things = [Thing(id: 99, kind: .pit, x: T.heroX - T.bodyW / 2 - 0.2, w: 40, h: 0)]
    cy.step(); check(!cy.onGround, "pit lip: no support")
    cy.press(); run(cy, 0.6)
    check(cy.phase == .running, "coyote jump saves the run")

    // Water: standing over a pit is fatal, by drowning.
    let pw = Game(seed: 1); pw.start(); pw.gapLeft = 1e9
    pw.things = [Thing(id: 99, kind: .pit, x: T.heroX - 10, w: 40, h: 0)]
    run(pw, 0.5)
    check(pw.phase == .dying || pw.phase == .over, "water pit is fatal")

    // Orbs: collected once; lethal collision resolves first.
    let o = Game(seed: 1); o.start(); o.gapLeft = 1e9
    o.things = [Thing(id: 7, kind: .orb, x: T.heroX - 2, y: 2, w: T.orbSize, h: T.orbSize)]
    run(o, 0.2)
    check(o.orbs == 1, "orb collected once (\(o.orbs))")
    let lo = Game(seed: 1); lo.start(); lo.gapLeft = 1e9
    lo.things = [Thing(id: 8, kind: .rock, x: T.heroX - 2, w: 7, h: 6), Thing(id: 9, kind: .orb, x: T.heroX - 2, y: 2, w: T.orbSize, h: T.orbSize)]
    lo.step()
    check(lo.phase == .dying && lo.orbs == 0, "lethal first: no orb credit on the death tick")

    // Pause and stalls add nothing.
    let ps = Game(seed: 1); ps.start(); run(ps, 1); let s0 = ps.score, d0 = ps.distance
    ps.pause(); run(ps, 5)
    check(ps.score == s0 && ps.distance == d0, "pause adds no distance or score")

    // Fair play: the bot runs 6 seeds x 5 minutes. Evolutions once each, on the ground; spawned hazards fair.
    var deaths = 0, violations = 0, evo = 0, drops = 0, cancels = 0, maxStage = 0
    for seed in 1...6 {
        let g = Game(seed: UInt64(seed)); g.autopilot = true; g.start()
        var lastBalloonStart = -1e9, overlap = false
        for _ in 0..<Int(300 / T.step) {
            let had = g.balloon != nil
            g.step()
            if !had && g.balloon != nil { if g.active - lastBalloonStart < T.balloonCooldown { overlap = true }; lastBalloonStart = g.active }
            for e in g.events { if case .evolved = e { check(g.onGround, "evolved on the ground") } }
            g.events.removeAll()
            if g.phase == .over { deaths += 1; evo += g.evolutions; g.start() }
        }
        check(!overlap, "balloon cooldown honoured (seed \(seed))")
        violations += g.windowViolations; evo += g.evolutions; drops += g.balloonDrops; cancels += g.balloonCancels; maxStage = max(maxStage, g.stage)
    }
    print("bot: \(deaths) deaths in 30 min, \(evo) evolutions, \(drops) balloon drops (\(cancels) cancelled as unfair), window violations \(violations)")
    check(violations == 0, "every spawned hazard leaves a >= 120 ms input window")
    check(maxStage == 2, "reaches the adult form")
    check(drops > 0, "balloon drops happen")
    check(deaths <= 2, "bot survives (generator is fair)")

    // Evolution happens exactly at the thresholds, never skipping the middle form.
    let ev = Game(seed: 3); ev.autopilot = true; ev.start()
    var stages: [Int] = []
    for _ in 0..<Int(90 / T.step) { ev.step(); for e in ev.events { if case .evolved(let s) = e { stages.append(s) } }; ev.events.removeAll() }
    check(stages == [1, 2], "evolutions in order once each: \(stages)")

    // Grunt ambush: a rolling capture orb captures you; jumping over a grunt defeats it.
    let cap = Game(seed: 1); cap.start(); cap.gapLeft = 1e9
    cap.things = [Thing(id: 5, kind: .capOrb, x: T.heroX + 6, w: 5, h: 5, vx: 8)]
    run(cap, 0.3)
    check(cap.captured && (cap.phase == .dying || cap.phase == .over), "a capture orb captures the hero")
    let gj = Game(seed: 1); gj.start(); gj.gapLeft = 1e9
    gj.things = [Thing(id: 6, kind: .grunt, x: T.heroX + 60, w: 7, h: 8, vx: 10)]
    gj.autopilot = true; run(gj, 1.5)
    check(gj.phase == .running && gj.defeats == 1 && gj.bonus == 25, "jumping over a grunt defeats it (+25)")
    var ambushes = 0, defeats = 0
    for seed in 1...6 {
        let g = Game(seed: UInt64(seed)); g.autopilot = true; g.start()
        run(g, 240)
        ambushes += g.ambushes; defeats += g.defeats
    }
    print("ambushes: \(ambushes), grunts defeated: \(defeats)")
    check(ambushes > 0 && defeats > 0, "grunt ambushes happen and grunts get defeated")

    // Restart resets the run but keeps the best score.
    ev.best = 500; ev.start()
    check(ev.stage == 0 && ev.score == 0 && ev.things.isEmpty && ev.best == 500, "restart resets run, keeps best")

    print(fails == 0 ? "selftest OK" : "selftest: \(fails) failures")
    return fails == 0 ? 0 : 1
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest()) }
if args.contains("--snapshot") { snapshot(args); exit(0) }
if args.contains("--record") { record(args); exit(0) }

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
