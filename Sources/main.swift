// Embertrail: a tiny endless runner in a transparent strip just above the macOS Dock.
// Rules live in Game.swift, sprites in Art.swift; this file draws, hosts the window and runs the tools.
import Cocoa

let px: CGFloat = 2                       // points per logical px
let stripH = T.top + T.bandDepth           // room for the taller jump, including final evolutions
let bandDepth = T.bandDepth
let jumpHelp = "Tap Space to jump · hold for height · Esc pauses"

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
    private let heroL = CALayer(), markerL = CALayer(), hudL = CALayer(), powerL = CALayer(), msgL = CALayer(), helpL = CALayer()
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
        for l in [heroL, markerL, hudL, powerL, msgL, helpL, buttonL, buttonText, changeText, titleL] { pix(l) }
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
            case .fruit(let id):
                if let t = g.things.first(where: { $0.id == id }) {
                    effects.append(Effect(kind: .sparkle, x: t.x + t.w / 2, y: t.y, life: 0.45))
                    effects.append(Effect(kind: .text("\(t.fruit.label) +\(t.fruit.points)"), x: g.heroX + 20, y: g.y + 24, life: 1.1))
                }
            case .died(let water):
                if water { effects.append(Effect(kind: .splash, x: g.heroX, y: -1, life: 0.6)) }
            case .evolved:
                effects.append(Effect(kind: .burst, x: g.heroX, y: 4, life: 0.5)); cheerUntil = g.clock + 1.6
            case .defeated(let id):
                if let t = g.things.first(where: { $0.id == id }) {
                    effects.append(Effect(kind: .sparkle, x: t.x + t.w / 2, y: 6, life: 0.4))
                    effects.append(Effect(kind: .text("+25"), x: t.x + t.w / 2, y: 14, life: 0.9))
                }
            case .crateHit(let lost):
                effects.append(Effect(kind: .text(lost > 0 ? "−\(lost)" : "BUMP"), x: g.heroX, y: g.y + 18, life: 0.9))
            case .trapOpened(let id):
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
        for pit in g.things where pit.kind == .pit {
            var x = pit.x
            while x < pit.x + pit.w {
                let w = min(16, pit.x + pit.w - x)
                let l = pooled("pitSurface")
                let frames = pit.pitType == .magma ? art.lava : (pit.pitType == .rock ? [art.soil[1]] : art.water)
                let img = frames[moving ? Int(clock * 5) % frames.count : 0]
                l.contents = img
                l.contentsRect = CGRect(x: 0, y: 0, width: w / 16, height: 1)
                l.frame = frame(x, -bandDepth, w, bandDepth + 1)
                if pit.pitType == .rock { sprite("pitRubble", art.rockSmall, feetX: x + w / 2, y: -6) }
                x += 16
            }
            if g.canCross(pit.pitType) {
                let safe = pooled("safePit")
                safe.backgroundColor = CGColor(red: 0.55, green: 1, blue: 0.65, alpha: 0.8)
                safe.frame = frame(pit.x, 0, pit.w, 0.75)
            }
        }

        // Things.
        for t in g.things where !t.gone {
            let cx = t.x + t.w / 2
            switch t.kind {
            case .rock: sprite("thing", art.rockSmall, feetX: cx, y: t.y)
            case .spike: put(pooled("thing"), art.spikes3.image, frame(t.x, 0, t.w, t.h))
            case .crate: sprite("thing", art.crate, feetX: cx, y: 0)
            case .boulder: sprite("thing", art.boulder, feetX: cx, y: 0)
            case .mole: sprite("thing", art.mole[moving ? Int(t.t * 9) % art.mole.count : 0], feetX: cx, y: 0)
            case .sign:
                sprite("thing", t.pitType == .water ? art.signWater : art.signWarn, feetX: cx, y: 0)
                let label = cachedText(t.pitType.label)
                let w = Double(label.width) / Double(backing * px), h = Double(label.height) / Double(backing * px)
                put(pooled("pitLabel"), label, frame(cx - w / 2, 15, w, h))
            case .fruit:
                let bob = moving ? (sin(t.t * 5) * 0.8).rounded() : 0
                sprite("thing", art.fruits[t.fruit.rawValue], feetX: cx, y: t.y + bob)
            case .pit: break
            case .fallingTrap:
                sprite("thing", art.captureClosed[0], feetX: cx, y: t.y)
            case .captureTrap:
                sprite("thing", art.captureOpen[5], feetX: cx, y: 0)
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
        put(heroL, hs.image, frame(g.heroX - hs.anchorX * g.heroScale, g.y, hs.w * g.heroScale, hs.h * g.heroScale))
        let hitFlash = g.crateHitT > 0 && moving && Int(g.crateHitT * 16) % 2 == 1
        heroL.opacity = g.phase == .dying && moving && Int(g.dyingT * 12) % 2 == 1 ? 0.25 : (hitFlash ? 0.55 : 1)
        heroL.isHidden = (picking && g.phase == .ready) || (g.phase == .dying && g.y < -6) || ((g.phase == .dying || g.phase == .over) && g.captured && g.dyingT > 0.2)
        if g.captured && (g.phase == .dying || g.phase == .over) {
            // The capture orb pops open, snaps shut around the starter, then wobbles three times.
            let k = g.dyingT
            let f: Sprite
            if k < 0.45 { f = art.captureOpen[max(0, min(art.captureOpen.count - 1, art.captureOpen.count - 1 - Int(k / 0.45 * Double(art.captureOpen.count))))] }
            else if k < 1.45 && moving { f = art.captureClosed[Int((k - 0.45) * 9) % art.captureClosed.count] }
            else { f = art.captureClosed[0] }
            let wob = k >= 0.45 && k < 1.45 && moving ? sin((k - 0.45) * 3 * 2 * .pi) * 1.5 : 0
            sprite("fx", f, feetX: g.heroX + wob, y: 0)
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
        let nextEvolution = g.stage < T.evolveScores.count ? "   EVOLVE \(T.evolveScores[g.stage])" : "   FINAL FORM"
        let hud = g.phase == .ready ? (g.best > 0 ? "BEST \(g.best)" : "") : "SCORE \(g.score)   FRUIT \(g.fruitsCollected)\(nextEvolution)"
        setText(hudL, hud, size: 9, leftX: 8, topY: size.height - 4)       // top left: the balloon hovers on the right
        let powerText = Fruit.allCases.compactMap { fruit -> String? in
            guard let remaining = g.powers[fruit] else { return nil }
            return "\(fruit.label) \(Int(ceil(remaining)))s"
        }.joined(separator: " · ")
        setText(powerL, powerText, size: 9, leftX: 8, topY: size.height - 20, weight: .heavy)
        var msg = ""
        switch g.phase {
        case .ready: msg = "EMBERTRAIL"
        case .paused: msg = "PAUSED"
        case .over: msg = "GAME OVER  ·  \(g.score)"
        case .running:
            if let balloon = g.balloon, balloon.stage == .telegraph || balloon.stage == .drop {
                msg = "TEAM ROCKET · CAPTURE BALL INCOMING"
            } else if !g.scheduled.isEmpty || g.things.contains(where: { $0.kind == .thrownOrb || $0.kind == .capOrb || $0.kind == .grunt || $0.kind == .captureTrap }) {
                msg = "TEAM ROCKET · JUMP THE CAPTURE ORBS"
            }
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
    override func keyUp(with e: NSEvent) { app?.jumpUp(Int(e.keyCode)) }
    override func mouseDown(with e: NSEvent) { app?.click() }
    override func mouseUp(with e: NSEvent) { app?.jumpUp(-1) }
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
    var jumpInputs: Set<Int> = []

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

        game.element = Element(rawValue: scene.starter) ?? .fire

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
    func jumpDown(_ source: Int) {
        guard game.phase == .running || game.phase == .evolving else { return }
        guard jumpInputs.insert(source).inserted else { return }
        if jumpInputs.count == 1 { game.press() }
    }
    func jumpUp(_ source: Int) {
        jumpInputs.remove(source)
        if jumpInputs.isEmpty { game.release() }
    }
    func key(_ e: NSEvent) {
        guard !e.isARepeat else { return }
        switch e.keyCode {
        case 49, 126: jumpDown(Int(e.keyCode))                                                    // Space, Up
        case 36, 76:                                                                              // Return, Enter
            if [.ready, .over, .paused].contains(game.phase) { game.press() }
        case 35: if game.phase == .paused { game.resume() } else { game.pause() }                 // P
        case 53: game.pause(); NSApp.deactivate()                                                 // Escape: pause, hand focus back
        default: break
        }
    }
    func click() {
        if game.phase == .running || game.phase == .evolving { jumpDown(-1); return }
        let p = view.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        guard let id = scene.buttons.first(where: { $0.value.insetBy(dx: -4, dy: -4).contains(p) })?.key else { return }
        if id == "play" { play() }
        else if id == "change" { game.phase = .ready; scene.picking = true }
        else if id.hasPrefix("pick"), let i = Int(id.dropFirst(4)), i < art.families.count {
            Prefs.starter = art.families[i].id; scene.starter = i; game.element = Element(rawValue: i) ?? .fire; scene.picking = false
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
        if game.phase != .running && game.phase != .evolving { jumpInputs.removeAll(); game.release() }
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
        game.phase == .ready ? jumpHelp : ""
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
        menu.addItem(info("    Fire: magma · Water: water · Grass: rock pits"))
        menu.addItem(info("    Evolution: 300 and 800 score"))
        let fruitMenu = NSMenuItem(title: "Fruit powers", action: nil, keyEquivalent: "")
        let fruitSubmenu = NSMenu()
        for description in ["Heart: +75 points", "Dark blue: giant for 6s", "Lightning: speed + automatic dodge for 6s",
                            "Green: one-hit shield for 8s", "Purple: fruit magnet for 6s", "Flame: magma walking for 6s",
                            "Ice blue: water walking for 6s", "Star: protection for 5s"] {
            fruitSubmenu.addItem(info(description))
        }
        fruitMenu.submenu = fruitSubmenu; menu.addItem(fruitMenu)
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
        scene.starter = n; game.element = Element(rawValue: n) ?? .fire; Prefs.starter = art.families[n].id; scene.picking = false
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
    scene.update(g, dt: dt, help: g.phase == .ready ? jumpHelp : "")
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
    scene.starter = min(2, max(0, Int(arg("--starter") ?? "0") ?? 0))
    g.element = Element(rawValue: scene.starter) ?? .fire
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
    print("wrote \(arg("--snapshot")!): phase \(g.phase) stage \(g.stage) score \(g.score) fruits \(g.fruitsCollected) t \(String(format: "%.1f", g.active))")
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
    scene.starter = min(2, max(0, Int(arg("--starter") ?? "0") ?? 0))
    g.element = Element(rawValue: scene.starter) ?? .fire
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
            let apexTop = T.crateHeight + T.jumpV * T.jumpV / (2 * T.gravity) + tallest * 1.6
            check(apexTop <= T.top, "\(f.name) stage \(i) apex top \(apexTop) within \(T.top)")
        }
    }
    check(art.fruits.count == 8 && art.sparkle.count == 6 && art.water.count == 6 && art.balloon.count == 6, "fruit/sparkle/water/balloon frames")

    // Dockosaur-inspired held arc, with a forgiving minimum tap jump.
    let p = Game(seed: 1); p.start(); p.gapLeft = 1e9
    p.press(); var apex = 0.0, air = 0.0
    repeat { p.step(); apex = max(apex, p.y); air += T.step } while !p.onGround && air < 2
    check(abs(apex - 42.48) < 0.3 && abs(air - 0.723) < 0.02, "held apex \(apex), airtime \(air)")
    let tap = Game(seed: 1); tap.start(); tap.gapLeft = 1e9
    tap.press(); tap.release(); var tapApex = 0.0, tapAir = 0.0
    repeat { tap.step(); tapApex = max(tapApex, tap.y); tapAir += T.step } while !tap.onGround && tapAir < 2
    check(abs(tapApex - 37.23) < 0.3 && abs(tapAir - 0.677) < 0.02 && tapApex < apex, "quick tap retains a useful arc (\(tapApex), \(tapAir))")
    let released = Game(seed: 1); released.start(); released.gapLeft = 1e9
    released.press(); run(released, 0.08); released.release()
    var releasedApex = released.y
    while !released.onGround { released.step(); releasedApex = max(releasedApex, released.y) }
    check(abs(releasedApex - tapApex) < 0.3, "release during ascent trims extra height smoothly")

    // Holding is one jump, never an OS-repeat-driven chain of automatic jumps.
    let held = Game(seed: 1); held.start(); held.gapLeft = 1e9; held.press(); run(held, 1.5)
    check(held.events.filter { if case .jumped = $0 { return true }; return false }.count == 1, "holding does not auto-repeat jumps")

    // A player can be 75 ms early or late on either tap or hold, against every ground obstacle.
    var clears = 0
    let groundTests = hazardSpecs + [HazardSpec(kind: .capOrb, w: 5, h: 5, vx: 8), HazardSpec(kind: .grunt, w: 7, h: 8, vx: 10), HazardSpec(kind: .captureTrap, w: 9, h: 8, vx: 0)]
    for speed in [T.startSpeed, 92.0, T.maxSpeed] {
        for hazard in groundTests {
            for hold in [false, true] {
                for offset in [-0.075, 0.0, 0.075] {
                    let g = Game(seed: 1); g.start(); g.gapLeft = 1e9
                    g.active = (speed - T.startSpeed) / T.accel
                    let flightCenter = (hold ? T.jumpV : T.tapV) / T.gravity
                    let x = T.heroX + (speed + hazard.vx) * (flightCenter + offset) - hazard.w / 2
                    g.things = [Thing(id: 99, kind: hazard.kind, x: x, w: hazard.w, h: hazard.h, vx: hazard.vx)]
                    g.press(); if !hold { g.release() }; run(g, 1.1)
                    let alive = g.phase != .dying && g.phase != .over && g.penalty == 0
                    check(alive, "\(hazard.kind) clears at speed \(speed), hold \(hold), timing offset \(offset)")
                    if alive { clears += 1 }
                }
            }
        }
    }
    print("forgiving jumps: \(clears)/144 early, centered, and late tap/hold clears")

    // Jump buffer: one press shortly before landing gives exactly one jump.
    let jb = Game(seed: 1); jb.start(); jb.gapLeft = 1e9
    jb.press(); run(jb, 0.64); jb.events.removeAll(); jb.press(); jb.release(); run(jb, 1.2)
    check(jb.events.filter { if case .jumped = $0 { return true }; return false }.count == 1, "jump buffer: one jump from one press")

    // Coyote: walking off a pit lip and pressing within 100 ms still jumps.
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
    o.things = [Thing(id: 7, kind: .fruit, x: T.heroX - 2, y: 2, w: T.fruitSize, h: T.fruitSize)]
    run(o, 0.2)
    check(o.fruitsCollected == 1, "fruit collected once (\(o.fruitsCollected))")
    let lo = Game(seed: 1); lo.start(); lo.gapLeft = 1e9
    lo.things = [Thing(id: 8, kind: .rock, x: T.heroX - 2, w: 7, h: 6), Thing(id: 9, kind: .fruit, x: T.heroX - 2, y: 2, w: T.fruitSize, h: T.fruitSize)]
    lo.step()
    check(lo.phase == .dying && lo.fruitsCollected == 0, "lethal first: no fruit credit on the death tick")

    // Pause and stalls add nothing.
    let ps = Game(seed: 1); ps.start(); run(ps, 1); let s0 = ps.score, d0 = ps.distance
    ps.pause(); run(ps, 5)
    check(ps.score == s0 && ps.distance == d0, "pause adds no distance or score")
    check(!ps.holding && ps.buffer == 0, "pause clears held and buffered input")

    // Crates are platforms on top and non-lethal, once-only penalties on the sides.
    let platform = Game(seed: 1); platform.start(); platform.gapLeft = 1e9
    platform.y = 10; platform.vy = -80; platform.onGround = false
    platform.things = [Thing(id: 90, kind: .crate, x: T.heroX - 4, w: 8, h: T.crateHeight)]
    run(platform, 0.025)
    check(platform.phase == .running && platform.onGround && platform.standingCrate == 90 && platform.y == T.crateHeight && platform.penalty == 0, "landing on a crate is safe")
    platform.press(); platform.release(); platform.step()
    check(!platform.onGround && platform.standingCrate == nil && platform.vy > 0 && platform.y > T.crateHeight, "jump again from the crate top")
    var crateApex = platform.y
    while !platform.onGround && platform.phase == .running {
        platform.step(); crateApex = max(crateApex, platform.y)
    }
    check(abs(crateApex - (T.crateHeight + 37.23)) < 0.3, "tap jump height is relative to the crate surface")

    let bufferedCrate = Game(seed: 1); bufferedCrate.start(); bufferedCrate.gapLeft = 1e9
    bufferedCrate.y = 10; bufferedCrate.vy = -80; bufferedCrate.onGround = false
    bufferedCrate.things = [Thing(id: 91, kind: .crate, x: T.heroX - 4, w: 8, h: T.crateHeight)]
    bufferedCrate.press(); bufferedCrate.release(); run(bufferedCrate, 0.05)
    check(bufferedCrate.y > T.crateHeight && bufferedCrate.vy > 0 && bufferedCrate.penalty == 0, "a buffered press chains a jump off the crate")

    let walkOff = Game(seed: 1); walkOff.start(); walkOff.gapLeft = 1e9
    walkOff.y = T.crateHeight; walkOff.standingCrate = 92
    walkOff.things = [Thing(id: 92, kind: .crate, x: T.heroX - 4, w: 8, h: T.crateHeight)]
    run(walkOff, 0.5)
    check(walkOff.onGround && walkOff.y == 0 && walkOff.standingCrate == nil && walkOff.phase == .running, "leaving a moving crate drops onto safe ground")

    let bump = Game(seed: 1); bump.start(); bump.gapLeft = 1e9; bump.distance = 800
    bump.things = [Thing(id: 93, kind: .crate, x: T.heroX + 4, w: 8, h: T.crateHeight)]
    bump.step()
    check(bump.phase == .running && bump.score == 90 && bump.penalty == 10, "crate side hit loses ten points instead of killing")
    run(bump, 0.1)
    check(bump.heroX < T.heroX - 5 && bump.penalty == 10, "crate hit moves the actual collision body backward and charges once")
    let offsetAtPause = bump.heroOffset; bump.pause(); run(bump, 1)
    check(bump.heroOffset == offsetAtPause, "pause freezes knockback")
    bump.resume(); run(bump, 2)
    check(bump.phase == .running && abs(bump.heroOffset) < 0.01 && bump.penalty == 10, "recover naturally without repeated charges from the same crate")
    bump.start()
    check(bump.penalty == 0 && bump.heroOffset == 0 && bump.standingCrate == nil, "restart clears crate damage and displacement")
    let emptyScore = Game(seed: 1); emptyScore.start(); emptyScore.gapLeft = 1e9
    emptyScore.things = [Thing(id: 94, kind: .crate, x: T.heroX + 4, w: 8, h: T.crateHeight)]
    emptyScore.step()
    check(emptyScore.score == 0 && emptyScore.penalty == 0 && emptyScore.phase == .running, "a crate bump cannot create negative points or future score debt")

    let underneath = Game(seed: 1); underneath.start(); underneath.gapLeft = 1e9
    underneath.y = 7; underneath.vy = 60; underneath.onGround = false; underneath.distance = 800
    underneath.things = [Thing(id: 95, kind: .crate, x: T.heroX - 4, y: 20, w: 8, h: T.crateHeight)]
    underneath.step()
    check(underneath.standingCrate == nil && underneath.penalty == 10 && underneath.phase == .running, "hitting a crate from below is not a top landing")

    // The balloon drops one harmless closed ball, which opens into a stationary capture trap.
    let trapDrop = Game(seed: 1); trapDrop.start(); trapDrop.gapLeft = 1e9
    var dropping = Game.Balloon(x: 230, y: 10)
    dropping.stage = .telegraph; dropping.t = 0.79; dropping.targetX = 230
    trapDrop.balloon = dropping; run(trapDrop, 0.05)
    let droppedID = trapDrop.things.first(where: { $0.kind == .fallingTrap })?.id
    check(droppedID != nil && trapDrop.balloonDrops == 1, "balloon creates exactly one falling ball")
    run(trapDrop, 0.4)
    check(trapDrop.things.contains { $0.id == droppedID && $0.kind == .captureTrap && $0.y == 0 && $0.vx == 0 }, "the same dropped ball opens on the ground without rolling")
    check(trapDrop.balloonDrops == 1 && !trapDrop.things.contains { $0.kind == .rock }, "balloon leaves a trap, not a rock")
    let trapped = Game(seed: 1); trapped.start(); trapped.gapLeft = 1e9
    trapped.things = [Thing(id: 96, kind: .captureTrap, x: T.heroX + 4, w: 9, h: 8)]
    trapped.step()
    check(trapped.captured && trapped.phase == .dying && trapped.events.contains { if case .captured = $0 { return true }; return false }, "touching an open ball starts the capture sequence")
    run(trapped, 1.7)
    check(trapped.phase == .over, "capture ends the run after the closing and wobble animation")

    // Score, rather than elapsed time, drives evolution; a big bonus never skips the middle form.
    let slowScore = Game(seed: 1); slowScore.start(); slowScore.active = 200; slowScore.gapLeft = 1e9
    run(slowScore, 0.1)
    check(slowScore.stage == 0 && slowScore.pendingStage == nil, "time alone cannot trigger evolution")
    let fruitEvolution = Game(seed: 1); fruitEvolution.start(); fruitEvolution.gapLeft = 1e9
    fruitEvolution.distance = Double(T.evolveScores[0] - Fruit.heart.points) * T.distPerPoint
    fruitEvolution.collect(.heart); run(fruitEvolution, 0.7)
    check(fruitEvolution.stage == 1 && fruitEvolution.evolutions == 1, "fruit bonus crosses the first evolution score")
    fruitEvolution.distance = Double(T.evolveScores[1] - fruitEvolution.fruitPoints) * T.distPerPoint
    run(fruitEvolution, 0.7)
    check(fruitEvolution.stage == 2 && fruitEvolution.evolutions == 2, "combined distance and fruit score reaches final evolution")
    let bigBonus = Game(seed: 1); bigBonus.start(); bigBonus.gapLeft = 1e9; bigBonus.fruitPoints = 900
    run(bigBonus, 1.5)
    let bonusStages = bigBonus.events.compactMap { event -> Int? in if case .evolved(let stage) = event { return stage }; return nil }
    check(bonusStages == [1, 2], "large score bonuses evolve in order")

    // Every starter has one matching safe pit, including all evolved forms.
    for element in Element.allCases {
        for pitType in PitType.allCases {
            for stage in 0...2 {
                let g = Game(seed: 1); g.element = element; g.start(); g.stage = stage; g.gapLeft = 1e9
                var pit = Thing(id: 100, kind: .pit, x: T.heroX - 10, w: 40, h: 0); pit.pitType = pitType
                g.things = [pit]; run(g, 0.2)
                let matches = (element == .fire && pitType == .magma) || (element == .water && pitType == .water) || (element == .grass && pitType == .rock)
                check(matches ? g.phase == .running && g.onGround : g.phase == .dying, "\(element) stage \(stage) crosses only its matching \(pitType) pit")
            }
        }
    }

    let big = Game(seed: 1); big.start(); big.gapLeft = 1e9; big.collect(.giant)
    big.things = [Thing(id: 101, kind: .rock, x: T.heroX + 4, w: 11, h: 8)]
    big.step()
    check(big.heroScale == 1.6 && big.phase == .running && big.things[0].gone, "dark-blue fruit enlarges the hero and smashes a rock")
    run(big, 7)
    check(big.heroScale == 1 && big.powers[.giant] == nil, "giant wears off on safe ground")

    let turbo = Game(seed: 1); turbo.start(); turbo.gapLeft = 1e9; turbo.collect(.thunder)
    turbo.things = [Thing(id: 102, kind: .spike, x: T.heroX + 70, w: 18, h: 8),
                    Thing(id: 103, kind: .rock, x: T.heroX + 240, w: 11, h: 8),
                    Thing(id: 104, kind: .pit, x: T.heroX + 380, w: 38, h: 0)]
    run(turbo, 0.5)
    check(turbo.speed > turbo.baseSpeed * 1.5, "lightning increases speed")
    for _ in 0..<Int(5 / T.step) { turbo.press(); turbo.release(); turbo.step() }
    check(turbo.phase == .running && turbo.events.contains { if case .jumped = $0 { return true }; return false }, "lightning dodges spikes, rocks and water automatically despite stray taps")
    let powerTime = turbo.powers[.thunder]; turbo.pause(); run(turbo, 3)
    check(turbo.powers[.thunder] == powerTime, "pause freezes power duration")
    turbo.resume(); run(turbo, 2)
    check(!turbo.autoDodge && abs(turbo.speed - turbo.baseSpeed) < 1, "turbo returns to normal speed safely")

    let shield = Game(seed: 1); shield.start(); shield.gapLeft = 1e9; shield.collect(.shield)
    shield.things = [Thing(id: 105, kind: .rock, x: T.heroX + 4, w: 11, h: 8)]
    shield.step()
    check(shield.phase == .running && shield.powers[.shield] == nil && shield.things[0].gone, "green fruit absorbs one collision")
    run(shield, 0.6); shield.things = [Thing(id: 106, kind: .rock, x: T.heroX + 4, w: 11, h: 8)]; shield.step()
    check(shield.phase == .dying, "shield cannot absorb a second hit")
    let shieldedCrate = Game(seed: 1); shieldedCrate.start(); shieldedCrate.gapLeft = 1e9; shieldedCrate.collect(.shield)
    shieldedCrate.things = [Thing(id: 110, kind: .crate, x: T.heroX + 4, w: 8, h: T.crateHeight)]
    shieldedCrate.step()
    check(shieldedCrate.penalty == 0 && shieldedCrate.knockbackV == 0 && shieldedCrate.powers[.shield] == nil, "shield absorbs a crate bump without point loss")

    let magnet = Game(seed: 1); magnet.start(); magnet.gapLeft = 1e9; magnet.collect(.magnet)
    magnet.things = [Thing(id: 107, kind: .fruit, x: T.heroX + 65, y: 20, w: T.fruitSize, h: T.fruitSize)]
    run(magnet, 0.5)
    check(magnet.fruitsCollected == 2 && magnet.fruitPoints == Fruit.magnet.points + Fruit.heart.points, "purple fruit pulls an elevated heart into the hero")

    for (fruit, pitType, element) in [(Fruit.flame, PitType.magma, Element.water), (.frost, .water, .fire)] {
        let g = Game(seed: 1); g.element = element; g.start(); g.gapLeft = 1e9; g.collect(fruit); g.powers[fruit] = 0.01
        var pit = Thing(id: 108, kind: .pit, x: T.heroX - 10, w: 40, h: 0); pit.pitType = pitType; g.things = [pit]
        run(g, 0.2)
        check(g.phase == .running && g.onGround && g.powers[fruit] != nil, "\(fruit) keeps the hero safe until clear of a \(pitType) pit")
        run(g, 1)
        check(g.powers[fruit] == nil && g.phase == .running, "\(fruit) ends after crossing safely")
    }
    let star = Game(seed: 1); star.start(); star.gapLeft = 1e9; star.collect(.star)
    star.things = [Thing(id: 109, kind: .captureTrap, x: T.heroX + 4, w: 9, h: 8)]
    star.step()
    check(!star.captured && star.phase == .running && star.things[0].gone, "star guard protects against capture balls")

    // No collectible streams: fruit is single-file and every spawn is at least nine seconds apart.
    let sparse = Game(seed: 17); sparse.autopilot = true; sparse.start()
    var lastFruit = -1e9, seenFruit = 0, seenPits = Set<Int>(), seenSpikes = false
    for _ in 0..<Int(300 / T.step) {
        sparse.step(); sparse.events.removeAll()
        if sparse.fruitSpawns != seenFruit {
            check(sparse.active - lastFruit >= 9 - T.step, "fruit spawns are spaced out")
            lastFruit = sparse.active; seenFruit = sparse.fruitSpawns
        }
        check(sparse.things.filter { $0.kind == .fruit && !$0.gone }.count <= 1, "at most one uncollected fruit")
        for t in sparse.things where t.kind == .pit { seenPits.insert(t.pitType.rawValue); check(t.w >= 30 && pitWindow(w: t.w, v: sparse.baseSpeed) >= T.minWindow, "wider pits remain jumpable") }
        for t in sparse.things where t.kind == .spike { seenSpikes = true; check(t.w >= 18, "spikes spawn in visible triple groups") }
    }
    check(seenFruit >= 10 && seenFruit <= 34 && seenPits.count == 3 && seenSpikes, "sparse fruit and all three pit types appear")

    // Exercise actual turbo control, without enabling the separate development autopilot.
    var turboFailures = 0
    for seed in 1...6 {
        let g = Game(seed: UInt64(seed)); g.element = Element(rawValue: (seed - 1) % 3)!; g.start()
        g.worldW = [240.0, 360.0, 500.0][(seed - 1) % 3]
        g.collect(.thunder); g.powers[.thunder] = 180
        for _ in 0..<Int(120 / T.step) {
            // Recollecting lightning refreshes a duration rather than stacking it, so keep this test powered.
            g.powers[.thunder] = 180
            g.press(); g.release(); g.step(); g.events.removeAll()
            if g.phase == .dying || g.phase == .over { turboFailures += 1; break }
        }
    }
    check(turboFailures == 0, "automatic turbo survives generated hazards across starter types and strip widths")
    print("turbo: \(turboFailures) failures across 12 simulated minutes without manual jumps")

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
    check(violations == 0, "every spawned hazard leaves a >= 180 ms tap-jump window")
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
