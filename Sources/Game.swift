// Embertrail simulation: pure game rules, no drawing or windows. Deterministic for a seed and input sequence.
//
// Coordinates: logical px, x to the right, y UP, ground surface at y = 0. The strip spans y = -4 (bottom of the
// thin ground/water band) to y = 46 (top). The world scrolls left past a hero whose feet sit at x = heroX.
import Foundation

enum T {   // tunables (handoff game-config.json defaults)
    static let step = 1.0 / 120
    static let maxCatchUp = 8            // fixed steps per frame at most; longer stalls pause instead
    static let gravity = 800.0
    static let jumpV = 176.0
    static let coyote = 0.07
    static let buffer = 0.10
    static let startSpeed = 72.0, maxSpeed = 112.0, accel = 0.35
    static let heroX = 84.0
    static let bodyW = 10.0, bodyH = 14.0
    static let top = 46.0, bandDepth = 4.0
    static let distPerPoint = 8.0, pointsPerOrb = 10
    static let evolveAt = [30.0, 75.0]
    static let evolveFreeze = 0.65
    static let minWindow = 0.12          // every spawned hazard must leave at least this much input timing slack
    static let onboarding = 3.0          // safe ground at the start of a run
    static let pitsFrom = 8.0
    static let balloonFrom = 20.0, balloonCooldown = 20.0
    static let orbSize = 9.0
}

struct RNG {   // SplitMix64
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

enum Phase: Equatable { case ready, running, evolving, paused, dying, over }

enum Kind: Equatable {
    case rock, spike, crate, boulder, crab, mole       // ground hazards
    case grunt                                          // Team Rocket member: jump over them to defeat it
    case gruntDown                                      // defeated grunt (scenery, swirly eyes)
    case thrownOrb                                      // capture orb in flight; harmless until it lands
    case capOrb                                         // capture orb rolling on the ground: touching it captures you
    case pit                                            // a real gap in the ground, water below
    case sign                                           // wave warning before a pit (scenery)
    case orb
    case fallingRock                                    // dropped by the balloon; harmless until it lands
}

struct Thing {
    let id: Int
    var kind: Kind
    var x: Double                // left edge of the collision box (screen logical px)
    var y: Double = 0            // bottom of the collision box
    var w: Double, h: Double
    var vx = 0.0                 // extra leftward speed (critters)
    var vy = 0.0                 // falling rock
    var t = 0.0                  // age, for animation
    var gone = false
    var isHazard: Bool { switch kind { case .rock, .spike, .crate, .boulder, .crab, .mole, .grunt, .capOrb: return true; default: return false } }
}

struct HazardSpec { let kind: Kind; let w: Double; let h: Double; let vx: Double }

let hazardSpecs: [HazardSpec] = [
    .init(kind: .rock, w: 7, h: 6, vx: 0), .init(kind: .spike, w: 5, h: 7, vx: 0),
    .init(kind: .crate, w: 8, h: 8, vx: 0), .init(kind: .boulder, w: 10, h: 8, vx: 0),
    .init(kind: .crab, w: 8, h: 6, vx: 14), .init(kind: .mole, w: 9, h: 7, vx: 9),
]

/// Seconds the hero's body spends higher than `h` during a full jump.
func timeAbove(_ h: Double) -> (Double, Double)? {
    let a = T.gravity / 2, b = T.jumpV
    let d = b * b - 4 * a * h
    guard d > 0 else { return nil }
    return ((b - d.squareRoot()) / (2 * a), (b + d.squareRoot()) / (2 * a))
}

/// Input timing slack for clearing a w x h obstacle approaching at `v`: how early/late the jump may be.
func jumpWindow(w: Double, h: Double, v: Double) -> Double {
    guard let (a, b) = timeAbove(max(h, 0.0001)) else { return -1 }
    return (b - a) - (w + T.bodyW) / v
}

/// Pits: the hero falls only when its whole body is over water, so the dangerous span is (w - body).
func pitWindow(w: Double, v: Double) -> Double { 2 * T.jumpV / T.gravity - max(0, w - T.bodyW) / v }

enum Event { case jumped, landed, orb(Int), died(water: Bool), evolved(Int), smashLanded(Int), balloonDrop, captured, defeated(Int), orbLanded(Int) }

final class Game {
    var phase = Phase.ready
    var pausedFrom = Phase.running
    var worldW = 360.0
    var rng: RNG
    // hero
    var y = 0.0, vy = 0.0, onGround = true
    var coyote = 0.0, buffer = 0.0, sinceLand = 1.0, sinceJump = 1.0
    var falling = false            // dropped into a pit
    // run
    var speed = T.startSpeed, active = 0.0, distance = 0.0, orbs = 0
    var stage = 0, pendingStage: Int? = nil, evolveT = 0.0, evolutions = 0
    var best = 0
    var things: [Thing] = []
    var nextID = 1
    var gapLeft = 0.0              // distance until the generator may place the next pattern
    var lastRight = -1e9           // right edge of the newest hazard/pit (screen x), scrolls with the world
    var events: [Event] = []
    var dyingT = 0.0, clock = 0.0
    var windowViolations = 0       // self-test metric: a hazard spawned without a fair input window
    // balloon
    var balloon: Balloon? = nil
    var lastBalloonEnd = -1e9
    var balloonVisits = 0, balloonDrops = 0, balloonCancels = 0
    var autopilot = false          // development bot (self-test, demo recording)

    struct Balloon {
        enum Stage { case enter, hover, telegraph, drop, retreat }
        var stage = Stage.enter
        var x: Double, y: Double
        var t = 0.0
        var targetX = 0.0           // world-anchored drop spot (screen x, scrolls)
        var rockID: Int? = nil
    }

    var bonus = 0                  // +25 per defeated grunt
    var captured = false           // the run ended in a capture orb (for the animation)
    var ambushes = 0, defeats = 0, lastAmbush = -1e9
    var scheduled: [(at: Double, what: Int)] = []   // ambush timeline: 0 = throw an orb, 1 = grunt runs in
    var score: Int { Int(distance / T.distPerPoint) + T.pointsPerOrb * orbs + bonus }

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { rng = RNG(s: seed) }

    // MARK: input

    func press() {
        switch phase {
        case .ready, .over: start()
        case .paused: resume()
        case .running: buffer = T.buffer
        default: break
        }
    }
    func pause() { if phase == .running || phase == .evolving { pausedFrom = phase; phase = .paused } }
    func resume() { if phase == .paused { phase = pausedFrom } }

    func start() {
        phase = .running
        y = 0; vy = 0; onGround = true; coyote = 0; buffer = 0; falling = false; sinceLand = 1; sinceJump = 1
        speed = T.startSpeed; active = 0; distance = 0; orbs = 0
        stage = 0; pendingStage = nil; evolveT = 0; evolutions = 0
        things = []; nextID = 1; events = []
        bonus = 0; captured = false; scheduled = []; lastAmbush = -1e9
        gapLeft = T.startSpeed * T.onboarding; lastRight = -1e9
        balloon = nil; lastBalloonEnd = -1e9
    }

    // MARK: simulation

    /// Advances one fixed step. Events from the step are appended to `events` (consumer clears them).
    func step() {
        let dt = T.step
        clock += dt
        for i in things.indices { things[i].t += dt }
        switch phase {
        case .ready, .over, .paused: return
        case .dying:
            dyingT += dt
            if falling { vy -= T.gravity * dt; y = max(y + vy * dt, -30) }
            if dyingT > (captured ? 1.6 : 0.6) { phase = .over }      // the capture wobble takes a little longer
            return
        case .evolving:
            evolveT += dt
            if let p = pendingStage, evolveT >= T.evolveFreeze / 2, stage != p { stage = p; evolutions += 1; events.append(.evolved(p)) }
            if evolveT >= T.evolveFreeze { pendingStage = nil; phase = .running; gapLeft = max(gapLeft, speed * 1.0) }
            return
        case .running: break
        }
        if autopilot { think() }

        // 1. Buffered input, once, if grounded or within coyote time.
        if buffer > 0 && (onGround || coyote > 0) {
            vy = T.jumpV; onGround = false; coyote = 0; buffer = 0; sinceJump = 0
            events.append(.jumped)
        }
        buffer = max(0, buffer - dt); coyote = max(0, coyote - dt)
        sinceLand += dt; sinceJump += dt

        // 2. Physics and world scroll.
        speed = min(T.maxSpeed, T.startSpeed + T.accel * active)
        let move = speed * dt
        distance += move
        active += dt
        for i in things.indices {
            things[i].x -= move + things[i].vx * dt
            if things[i].kind == .fallingRock {
                things[i].vy -= T.gravity * 0.6 * dt
                things[i].y = max(0, things[i].y + things[i].vy * dt)
                if things[i].y == 0 { things[i].kind = .rock; events.append(.smashLanded(things[i].id)) }   // same entity becomes the hazard
            }
            if things[i].kind == .thrownOrb {
                things[i].y += things[i].vy * dt - 200 * dt * dt; things[i].vy -= 400 * dt
                if things[i].y <= 0 { things[i].y = 0; things[i].kind = .capOrb; things[i].vx = 8; events.append(.orbLanded(things[i].id)) }
            }
        }
        lastRight -= move
        if var b = balloon {
            advanceBalloon(&b, move: move, dt: dt)
            if b.stage == .retreat && b.x > worldW + 40 { balloon = nil; lastBalloonEnd = active } else { balloon = b }
        }
        things.removeAll { $0.x + $0.w < -40 }
        while let next = scheduled.first, active >= next.at {
            scheduled.removeFirst()
            if next.what == 0 {   // thrown from just past the right edge: arcs in, lands, rolls toward you
                var o = add(.thrownOrb, x: worldW + 8, y: 18, w: 5, h: 5, vx: 35); o.vy = 60
                if let i = things.firstIndex(where: { $0.id == o.id }) { things[i].vy = 60 }
                _ = o
            } else {
                _ = add(.grunt, x: worldW + 4, w: 7, h: 8, vx: 10)
            }
        }
        // A grunt that went past without touching you was jumped over: it's defeated.
        for i in things.indices where things[i].kind == .grunt && things[i].x + things[i].w < T.heroX - T.bodyW / 2 {
            things[i].kind = .gruntDown; things[i].vx = 0; bonus += 25; defeats += 1
            events.append(.defeated(things[i].id))
        }

        let support = !overPit()
        if !onGround {
            y += vy * dt - T.gravity / 2 * dt * dt            // exact per step: the jump peaks at 19.36 px as designed
            vy -= T.gravity * dt
            if y <= 0 && vy <= 0 && support && !falling { y = 0; vy = 0; onGround = true; sinceLand = 0; events.append(.landed) }
            if y < -T.bandDepth { die(water: true); return }
        } else if !support {
            onGround = false; falling = true; coyote = T.coyote; vy = 0   // walked off a pit lip
        }
        if falling && y <= 0 && support && vy <= 0 { falling = false; y = 0; vy = 0; onGround = true }   // coyote jump saved it
        if !onGround && vy > 0 { falling = false }

        // 3. Lethal collisions first.
        let bx0 = T.heroX - T.bodyW / 2, bx1 = T.heroX + T.bodyW / 2
        for t in things where t.isHazard && !t.gone {
            if t.x < bx1 && t.x + t.w > bx0 && y < t.y + t.h && y + T.bodyH > t.y {
                if t.kind == .capOrb { captured = true; events.append(.captured) }
                die(water: false); return
            }
        }
        // 4. Still alive: collect orbs once.
        for i in things.indices where things[i].kind == .orb && !things[i].gone {
            let t = things[i]
            if t.x < bx1 && t.x + t.w > bx0 && y < t.y + t.h && y + T.bodyH > t.y {
                things[i].gone = true; orbs += 1; events.append(.orb(t.id))
            }
        }

        // 5. Generator and evolution.
        for (k, at) in T.evolveAt.enumerated() where active >= at && stage < k + 1 && pendingStage == nil { pendingStage = k + 1 }
        if let p = pendingStage {
            let clear = !things.contains { ($0.isHazard || $0.kind == .pit || $0.kind == .fallingRock) && $0.x + $0.w > T.heroX - 8 }
            if clear && onGround && balloon == nil { phase = .evolving; evolveT = 0; _ = p }
        } else {
            gapLeft -= move
            let balloonArriving = balloon.map { $0.stage == .enter || $0.stage == .hover } ?? false
            if gapLeft <= 0 && (worldW + 4) - lastRight >= 0 && !balloonArriving { spawn() }   // keep its drop zone clear
            let ambushOn = !scheduled.isEmpty || things.contains { $0.kind == .grunt || $0.kind == .capOrb || $0.kind == .thrownOrb }
            if balloon == nil && !ambushOn && active >= T.balloonFrom && active - lastBalloonEnd >= T.balloonCooldown && rng.unit() < 0.004 {
                balloon = Balloon(x: worldW + 30, y: 10); balloonVisits += 1
            }
        }
    }

    func overPit() -> Bool {
        things.contains { $0.kind == .pit && $0.x <= T.heroX - T.bodyW / 2 && $0.x + $0.w >= T.heroX + T.bodyW / 2 }
    }

    private func die(water: Bool) {
        phase = .dying; dyingT = 0
        if !water { falling = false }
        events.append(.died(water: water))
        if score > best { best = score }
    }

    private func add(_ k: Kind, x: Double, y: Double = 0, w: Double, h: Double, vx: Double = 0) -> Thing {
        let t = Thing(id: nextID, kind: k, x: x, y: y, w: w, h: h, vx: vx)
        nextID += 1; things.append(t)
        return t
    }

    // MARK: fair pattern generator

    private func spawn() {
        let v = speed
        let x0 = worldW + 4
        // Decision spacing: gentle early, never under ~0.9 s.
        let gapT = active < 20 ? rng.range(1.4, 2.2) : rng.range(0.95, 1.7)
        var right = x0
        let roll = rng.unit()
        let ambushOK = active >= 30 && active - lastAmbush >= 18 && balloon == nil && scheduled.isEmpty
            && (worldW + 4 - lastRight) >= v * 0.95 + 70
            && jumpWindow(w: 5, h: 5, v: v + 8) >= T.minWindow && jumpWindow(w: 7, h: 8, v: v + 10) >= T.minWindow
        if ambushOK && rng.unit() < 0.35 {
            // Grunt ambush: two orbs thrown 0.95 s apart (they land and roll in on the same path, so they
            // arrive 0.95 s apart), then the grunt runs in 2.0 s after the first throw.
            scheduled = [(active, 0), (active + 0.95, 0), (active + 2.0, 1)]
            ambushes += 1; lastAmbush = active
            lastRight = x0 + v * 2.0 + 7
            gapLeft = v * 2.0 + 7 + v * gapT
            return
        }
        if active >= T.pitsFrom && roll < 0.22 {
            // Wave sign first (decorative), then the pit 1.2 s later.
            let w = rng.range(12, 18).rounded()
            let pitX = x0 + v * 1.2
            if pitWindow(w: w, v: v) < T.minWindow { windowViolations += 1 }
            _ = add(.sign, x: x0, w: 10, h: 13)
            _ = add(.pit, x: pitX, w: w, h: 0)
            right = pitX + w
        } else if roll < 0.34 {
            // Free orbs on the ground.
            for i in 0..<3 { _ = add(.orb, x: x0 + Double(i) * 14, y: 1, w: T.orbSize, h: T.orbSize) }
            right = x0 + 28 + T.orbSize
            gapLeft = v * 0.5 + (right - x0)
            lastRight = max(lastRight, right - 30)    // orbs don't need a full decision gap
            return
        } else {
            let fair = hazardSpecs.filter { s in
                let rel = v + s.vx
                if s.kind == .crab || s.kind == .mole { if active < 12 { return false } }
                return jumpWindow(w: s.w, h: s.h, v: rel) >= T.minWindow
            }
            let s = fair[rng.int(fair.count)]
            if jumpWindow(w: s.w, h: s.h, v: v + s.vx) < T.minWindow { windowViolations += 1 }
            let hz = add(s.kind, x: x0, w: s.w, h: s.h, vx: s.vx)
            right = x0 + s.w
            if rng.unit() < 0.35 && s.vx == 0 {
                // Orb arc along an ideal jump over this hazard: it shows the safe path, never lures into danger.
                let takeoffX = hz.x + hz.w / 2 - v * (2 * T.jumpV / T.gravity) / 2
                for k in 1...3 {
                    let t = Double(k) * 0.11
                    let oy = T.jumpV * t - T.gravity / 2 * t * t + 3
                    _ = add(.orb, x: takeoffX + v * t - T.orbSize / 2, y: oy, w: T.orbSize, h: T.orbSize)
                }
            }
        }
        lastRight = right
        gapLeft = (right - x0) + v * gapT
    }

    // MARK: balloon gang

    private func advanceBalloon(_ b: inout Balloon, move: Double, dt: Double) {
        b.t += dt
        let hoverX = worldW - 50
        switch b.stage {
        case .enter:
            b.x -= 60 * dt
            if b.x <= hoverX { b.x = hoverX; b.stage = .hover; b.t = 0 }
        case .hover:
            if b.t > 1.0 {
                // Schedule a drop only if the spot is far enough ahead and clear of every other obstacle.
                let target = b.x
                let lead = (target - (T.heroX + T.bodyW / 2)) / speed
                let clear = !things.contains { ($0.isHazard || $0.kind == .pit || $0.kind == .sign) && abs(($0.x + $0.w / 2) - target) < speed * 0.9 }
                if lead >= max(1.6, 1.15 + 0.6) && clear {          // >= 1.6 s when scheduled, >= 0.6 s left after landing
                    b.stage = .telegraph; b.t = 0; b.targetX = target
                    lastRight = max(lastRight, target + 6)          // generator keeps a full gap after the rock
                    gapLeft = max(gapLeft, (target + 6 - (worldW + 4)) + speed * 0.95)
                } else {
                    balloonCancels += 1; b.stage = .retreat; b.t = 0
                }
            }
        case .telegraph:
            b.x -= move; b.targetX -= move                           // drifts with the ground it marks
            if b.t >= 0.8 {
                let r = add(.fallingRock, x: b.targetX - 3, y: b.y + 2, w: 6, h: 6)
                b.rockID = r.id; b.stage = .drop; b.t = 0; balloonDrops += 1
                events.append(.balloonDrop)
            }
        case .drop:
            b.x -= move; b.targetX -= move
            if b.t > 0.5 { b.stage = .retreat; b.t = 0 }
        case .retreat:
            b.x += 70 * dt; b.y += 8 * dt
        }
    }

    // MARK: development bot (tests and demo recording only)

    private func think() {
        guard onGround || coyote > 0 else { return }
        let front = T.heroX + T.bodyW / 2
        let ahead = things.filter { ($0.isHazard || $0.kind == .pit) && $0.x + $0.w > T.heroX - T.bodyW / 2 }
        guard let n = ahead.min(by: { $0.x < $1.x }) else { return }
        let v = speed + n.vx
        if n.kind == .pit {
            // Dangerous while the whole body is over water: take off mid-way through the safe window.
            let span = max(0, n.w - T.bodyW), air = v * 2 * T.jumpV / T.gravity
            if (n.x - (T.heroX - T.bodyW / 2)) <= (air - span) / 2 { buffer = T.buffer }
            return
        }
        guard let (a, b) = timeAbove(n.h + 0.5) else { return }
        if n.x - front - (v * (a + b) / 2 - (n.w + T.bodyW) / 2) <= 0 { buffer = T.buffer }
    }
}
