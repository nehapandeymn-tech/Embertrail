// Embertrail simulation: pure game rules, no drawing or windows. Deterministic for a seed and input sequence.
//
// Coordinates: logical px, x to the right, y UP, ground surface at y = 0. The strip spans y = -4 (bottom of the
// thin ground/water band) to y = 96 (top). The world scrolls left past a hero whose feet sit at x = heroX.
import Foundation

enum T {   // tunables (handoff game-config.json defaults)
    static let step = 1.0 / 120
    static let maxCatchUp = 8            // fixed steps per frame at most; longer stalls pause instead
    static let gravity = 650.0
    static let jumpV = 235.0             // held jump: ~42 px apex, 0.72 s airtime
    static let tapV = 220.0              // tap clears triple spikes and wider pits (~37 px, 0.68 s)
    static let coyote = 0.10
    static let buffer = 0.16
    static let startSpeed = 72.0, maxSpeed = 112.0, accel = 0.35
    static let heroX = 84.0
    static let bodyW = 10.0, bodyH = 14.0
    static let top = 96.0, bandDepth = 4.0
    static let crateHeight = 9.0, cratePenalty = 10
    static let distPerPoint = 8.0
    static let evolveScores = [300, 800]
    static let evolveFreeze = 0.65
    static let minWindow = 0.18          // minimum timing slack even for the shorter tap jump
    static let recoveryGap = 1.25        // seconds between ordinary hazard patterns
    static let onboarding = 3.0          // safe ground at the start of a run
    static let pitsFrom = 8.0
    static let balloonFrom = 20.0, balloonCooldown = 20.0
    static let fruitSize = 11.0
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

enum Element: Int, CaseIterable { case fire, grass, water }
enum PitType: Int, CaseIterable {
    case water, magma, rock
    var label: String { ["WATER", "MAGMA", "ROCK PIT"][rawValue] }
}
enum Fruit: Int, CaseIterable {
    case heart, giant, thunder, shield, magnet, flame, frost, star
    var points: Int { self == .heart ? 75 : (self == .star ? 40 : 20) }
    var duration: Double { self == .heart ? 0 : (self == .shield ? 8 : (self == .star ? 5 : 6)) }
    var label: String { ["HEART", "GIANT", "AUTO TURBO", "SHIELD", "MAGNET", "FIRE WALK", "WATER WALK", "STAR GUARD"][rawValue] }
}

enum Kind: Equatable {
    case rock, spike, crate, boulder, mole       // ground hazards
    case grunt                                          // Team Rocket member: jump over them to defeat it
    case gruntDown                                      // defeated grunt (scenery, swirly eyes)
    case thrownOrb                                      // capture orb in flight; harmless until it lands
    case capOrb                                         // capture orb rolling on the ground: touching it captures you
    case pit                                            // a real gap in the ground, water below
    case sign                                           // wave warning before a pit (scenery)
    case fruit
    case fallingTrap                                    // balloon-dropped ball; harmless in flight
    case captureTrap                                    // open ball on the ground; touching it captures the runner
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
    var bumped = false           // a crate can deduct points only once
    var fruit = Fruit.heart
    var pitType = PitType.water
    var isHazard: Bool { switch kind { case .rock, .spike, .crate, .boulder, .mole, .grunt, .capOrb, .captureTrap: return true; default: return false } }
}

struct HazardSpec { let kind: Kind; let w: Double; let h: Double; let vx: Double }

let hazardSpecs: [HazardSpec] = [
    .init(kind: .rock, w: 11, h: 8, vx: 0), .init(kind: .spike, w: 18, h: 8, vx: 0),
    .init(kind: .crate, w: 8, h: T.crateHeight, vx: 0), .init(kind: .boulder, w: 14, h: 10, vx: 0),
    .init(kind: .mole, w: 9, h: 7, vx: 9),
]

/// Seconds the hero's body spends higher than `h` during a full jump.
func timeAbove(_ h: Double, launchV: Double = T.jumpV) -> (Double, Double)? {
    let a = T.gravity / 2, b = launchV
    let d = b * b - 4 * a * h
    guard d > 0 else { return nil }
    return ((b - d.squareRoot()) / (2 * a), (b + d.squareRoot()) / (2 * a))
}

/// Input timing slack for clearing a w x h obstacle approaching at `v`: how early/late the jump may be.
func jumpWindow(w: Double, h: Double, v: Double) -> Double {
    guard let (a, b) = timeAbove(max(h, 0.0001), launchV: T.tapV) else { return -1 }
    return (b - a) - (w + T.bodyW) / v
}

/// Pits: the hero falls only when its whole body is over water, so the dangerous span is (w - body).
func pitWindow(w: Double, v: Double) -> Double { 2 * T.tapV / T.gravity - max(0, w - T.bodyW) / v }

enum Event { case jumped, landed, fruit(Int), died(water: Bool), evolved(Int), trapOpened(Int), balloonDrop, captured, defeated(Int), orbLanded(Int), crateHit(Int) }

final class Game {
    var phase = Phase.ready
    var pausedFrom = Phase.running
    var worldW = 360.0
    var rng: RNG
    // hero
    var y = 0.0, vy = 0.0, onGround = true
    var coyote = 0.0, buffer = 0.0, sinceLand = 1.0, sinceJump = 1.0
    var falling = false            // dropped into a pit
    var holding = false
    var standingCrate: Int? = nil
    var jumpOriginY = 0.0
    var heroOffset = 0.0, knockbackV = 0.0, crateHitT = 0.0
    var heroX: Double { T.heroX + heroOffset }
    var element = Element.fire
    var powers: [Fruit: Double] = [:]
    var fruitPoints = 0, fruitSpawns = 0
    var nextFruitAt = 5.0
    var boostBlend = 0.0
    var protectedUntil = 0.0
    var baseSpeed: Double { min(T.maxSpeed, T.startSpeed + T.accel * active) }
    var autoDodge: Bool { powers[.thunder, default: 0] > 0 }
    var giant: Bool { powers[.giant, default: 0] > 0 }
    var heroScale: Double { giant ? 1.6 : 1 }
    var guarded: Bool { powers[.star, default: 0] > 0 || active < protectedUntil }

    func canCross(_ pit: PitType) -> Bool {
        if guarded { return true }
        switch pit {
        case .water: return element == .water || powers[.frost, default: 0] > 0
        case .magma: return element == .fire || powers[.flame, default: 0] > 0
        case .rock: return element == .grass
        }
    }

    func collect(_ fruit: Fruit) {
        fruitPoints += fruit.points; fruitsCollected += 1
        if fruit.duration > 0 { powers[fruit] = fruit.duration }
        if fruit == .thunder { holding = false; buffer = 0 }
    }
    // run
    var speed = T.startSpeed, active = 0.0, distance = 0.0, fruitsCollected = 0
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
        var trapID: Int? = nil
    }

    var bonus = 0                  // +25 per defeated grunt
    var penalty = 0                // crate bumps; only points already earned can be deducted
    var captured = false           // the run ended in a capture orb (for the animation)
    var ambushes = 0, defeats = 0, lastAmbush = -1e9
    var scheduled: [(at: Double, what: Int)] = []   // ambush timeline: 0 = throw an orb, 1 = grunt runs in
    var score: Int { max(0, Int(distance / T.distPerPoint) + fruitPoints + bonus - penalty) }

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { rng = RNG(s: seed) }

    // MARK: input

    func press() {
        switch phase {
        case .ready, .over: start()
        case .paused: resume()
        case .running, .evolving: if !autoDodge { holding = true; buffer = T.buffer }
        default: break
        }
    }
    func release() {
        holding = false
        // Keep a forgiving minimum arc even if down/up arrive before the next physics step.
        // Release cuts only the extra height of a held jump; it never forces a sudden fall.
        if phase == .running && !onGround && vy > 0 && !autopilot && !autoDodge {
            let height = max(0, y - jumpOriginY)
            let tapVelocity = sqrt(max(0, T.tapV * T.tapV - 2 * T.gravity * height))
            if height < T.tapV * T.tapV / (2 * T.gravity) { vy = min(vy, tapVelocity) }
        }
    }
    func pause() {
        if phase == .running || phase == .evolving {
            release(); buffer = 0; pausedFrom = phase; phase = .paused
        }
    }
    func resume() { if phase == .paused { phase = pausedFrom } }

    func start() {
        phase = .running
        y = 0; vy = 0; onGround = true; coyote = 0; buffer = 0; falling = false; holding = false; sinceLand = 1; sinceJump = 1
        standingCrate = nil; jumpOriginY = 0; heroOffset = 0; knockbackV = 0; crateHitT = 0; penalty = 0
        powers = [:]; fruitPoints = 0; fruitSpawns = 0; nextFruitAt = 5; boostBlend = 0; protectedUntil = 0
        speed = T.startSpeed; active = 0; distance = 0; fruitsCollected = 0
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
        // Do not drop a temporary movement/protection power halfway across a pit or hazard.
        let safeToExpire = onGround && !things.contains {
            ($0.isHazard || $0.kind == .pit) && !$0.gone && $0.x + $0.w > heroX - 10 && $0.x < heroX + baseSpeed * 0.65
        }
        for power in Array(powers.keys) {
            let remaining = powers[power]! - dt
            if remaining > 0 { powers[power] = remaining }
            else if safeToExpire || power == .magnet || power == .shield { powers.removeValue(forKey: power) }
            else { powers[power] = dt }
        }
        let targetBoost = autoDodge ? 1.0 : 0.0
        boostBlend += max(-dt * 4, min(dt * 4, targetBoost - boostBlend))
        speed = baseSpeed * (1 + 0.6 * boostBlend)
        // Actual horizontal displacement, shared by rendering, collisions, pits, and pickups.
        crateHitT = max(0, crateHitT - dt)
        heroOffset = max(-28, heroOffset + knockbackV * dt)
        knockbackV *= exp(-10 * dt)
        if crateHitT < 0.45 { heroOffset = min(0, heroOffset + 28 * dt) }
        if autopilot || autoDodge { think() }

        // 1. Buffered input, once, if grounded or within coyote time.
        if buffer > 0 && (onGround || coyote > 0) {
            jumpOriginY = y; standingCrate = nil
            vy = holding || autopilot || autoDodge ? T.jumpV : T.tapV; onGround = false; coyote = 0; buffer = 0; sinceJump = 0
            events.append(.jumped)
        }
        buffer = max(0, buffer - dt); coyote = max(0, coyote - dt)
        sinceLand += dt; sinceJump += dt

        // 2. Physics and world scroll.
        let move = speed * dt
        distance += move
        active += dt
        for i in things.indices {
            things[i].x -= move + things[i].vx * dt
            if things[i].kind == .fruit && powers[.magnet, default: 0] > 0 && abs(things[i].x - heroX) < 90 {
                things[i].x += (heroX - things[i].x) * min(1, dt * 9)
                things[i].y += (y + 5 - things[i].y) * min(1, dt * 9)
            }
            if things[i].kind == .fallingTrap {
                things[i].vy -= T.gravity * 0.6 * dt
                things[i].y = max(0, things[i].y + things[i].vy * dt)
                if things[i].y == 0 { things[i].kind = .captureTrap; events.append(.trapOpened(things[i].id)) }   // same entity becomes the hazard
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
        for i in things.indices where things[i].kind == .grunt && things[i].x + things[i].w < heroX - T.bodyW / 2 {
            things[i].kind = .gruntDown; things[i].vx = 0; bonus += 25; defeats += 1
            events.append(.defeated(things[i].id))
        }

        let support = !overPit()
        let left = heroX - T.bodyW / 2, right = heroX + T.bodyW / 2
        if onGround {
            if let id = standingCrate {
                if let crate = things.first(where: { $0.id == id && !$0.gone && $0.x < right && $0.x + $0.w > left }) {
                    y = crate.y + crate.h
                } else {
                    standingCrate = nil; onGround = false; coyote = T.coyote; vy = 0
                }
            } else if !support {
                onGround = false; falling = true; coyote = T.coyote; vy = 0
            }
        }
        if !onGround {
            let previousY = y
            y += vy * dt - T.gravity / 2 * dt * dt
            vy -= T.gravity * dt
            // Only a downward crossing of the top is a landing. Side/underside contacts are bumps.
            let platform = things.filter {
                $0.kind == .crate && !$0.gone && $0.x < right && $0.x + $0.w > left
                    && vy <= 0 && previousY >= $0.y + $0.h && y <= $0.y + $0.h
            }.max { $0.y + $0.h < $1.y + $1.h }
            if let crate = platform {
                y = crate.y + crate.h; vy = 0; onGround = true; falling = false
                standingCrate = crate.id; sinceLand = 0; events.append(.landed)
            } else if y <= 0 && vy <= 0 && support {
                y = 0; vy = 0; onGround = true; falling = false; standingCrate = nil
                sinceLand = 0; events.append(.landed)
            }
            if y < -T.bandDepth { die(water: true); return }
        }
        if !onGround && vy > 0 { falling = false }

        // 3. Lethal collisions first.
        let bx0 = heroX - T.bodyW / 2, bx1 = heroX + T.bodyW / 2
        for i in things.indices where things[i].isHazard && things[i].kind != .crate && !things[i].gone {
            let t = things[i]
            if t.x < bx1 && t.x + t.w > bx0 && y < t.y + t.h && y + T.bodyH > t.y {
                if giant || guarded || powers[.shield, default: 0] > 0 {
                    things[i].gone = true
                    if !giant && !guarded { powers.removeValue(forKey: .shield); protectedUntil = active + 0.5 }
                    continue
                }
                if t.kind == .capOrb || t.kind == .captureTrap { captured = true; events.append(.captured) }
                die(water: false); return
            }
        }
        // Crate sides cost points and knock the runner back, without ending the run.
        for i in things.indices where things[i].kind == .crate && !things[i].gone && !things[i].bumped {
            let t = things[i]
            if t.x < bx1 && t.x + t.w > bx0 && y < t.y + t.h && y + T.bodyH > t.y {
                if giant || guarded || powers[.shield, default: 0] > 0 {
                    things[i].gone = true
                    if !giant && !guarded { powers.removeValue(forKey: .shield); protectedUntil = active + 0.5 }
                    continue
                }
                things[i].bumped = true
                let lost = min(T.cratePenalty, score); penalty += lost
                knockbackV = -180; crateHitT = 0.8
                events.append(.crateHit(lost))
            }
        }
        // 4. Still alive: collect each fruit once.
        for i in things.indices where things[i].kind == .fruit && !things[i].gone {
            let t = things[i]
            if t.x < bx1 && t.x + t.w > bx0 && y < t.y + t.h && y + T.bodyH > t.y {
                things[i].gone = true; collect(t.fruit); events.append(.fruit(t.id))
            }
        }

        // 5. Generator and evolution.
        if stage < T.evolveScores.count && score >= T.evolveScores[stage] && pendingStage == nil { pendingStage = stage + 1 }
        if let p = pendingStage {
            let clear = !things.contains { ($0.isHazard || $0.kind == .pit || $0.kind == .fallingTrap) && !$0.gone && $0.x + $0.w > heroX - 8 }
            if clear && onGround && standingCrate == nil && balloon == nil { phase = .evolving; evolveT = 0; _ = p }
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
        things.contains { $0.kind == .pit && !canCross($0.pitType) && $0.x <= heroX - T.bodyW / 2 && $0.x + $0.w >= heroX + T.bodyW / 2 }
    }

    private func die(water: Bool) {
        phase = .dying; dyingT = 0
        if !water { falling = false }
        events.append(.died(water: water))
        if score > best { best = score }
    }

    private func add(_ k: Kind, x: Double, y: Double = 0, w: Double, h: Double, vx: Double = 0, fruit: Fruit = .heart, pitType: PitType = .water) -> Thing {
        var t = Thing(id: nextID, kind: k, x: x, y: y, w: w, h: h, vx: vx)
        t.fruit = fruit; t.pitType = pitType
        nextID += 1; things.append(t)
        return t
    }

    // MARK: fair pattern generator

    private func spawn() {
        let v = speed, x0 = worldW + 4
        let gapT = active < 20 ? rng.range(1.8, 2.5) : rng.range(T.recoveryGap, 1.9)
        var right = x0
        if active >= nextFruitAt && !things.contains(where: { $0.kind == .fruit && !$0.gone }) {
            let introductory: [Fruit] = [.heart, .thunder, .giant]
            let fruit = fruitSpawns < introductory.count ? introductory[fruitSpawns] : Fruit.allCases[rng.int(Fruit.allCases.count)]
            _ = add(.fruit, x: x0, y: 2, w: T.fruitSize, h: T.fruitSize, fruit: fruit)
            fruitSpawns += 1; nextFruitAt = active + rng.range(9, 14)
            gapLeft = v * T.recoveryGap + T.fruitSize
            return
        }
        let roll = rng.unit()
        let ambushOK = active >= 30 && active - lastAmbush >= 18 && balloon == nil && scheduled.isEmpty
            && (worldW + 4 - lastRight) >= v * T.recoveryGap + 40
        if ambushOK && rng.unit() < 0.35 {
            scheduled = [(active, 0), (active + 1.25, 0), (active + 2.6, 1)]
            ambushes += 1; lastAmbush = active
            lastRight = x0 + v * 2.6 + 7
            gapLeft = v * 2.6 + 7 + v * gapT
            return
        }
        if active >= T.pitsFrom && roll < 0.25 {
            // Size for the unboosted speed: still safe if turbo expires before reaching the pit.
            let w = (rng.range(30, 38) + (baseSpeed - T.startSpeed) * 0.25).rounded()
            let pitX = x0 + v * 1.2
            let type = PitType.allCases[rng.int(PitType.allCases.count)]
            if pitWindow(w: w, v: baseSpeed) < T.minWindow { windowViolations += 1 }
            _ = add(.sign, x: x0, w: 10, h: 13, pitType: type)
            _ = add(.pit, x: pitX, w: w, h: 0, pitType: type)
            right = pitX + w
        } else {
            let fair = hazardSpecs.filter { s in
                if s.kind == .mole && active < 12 { return false }
                return jumpWindow(w: s.w, h: s.h, v: baseSpeed + s.vx) >= T.minWindow
            }
            let s = fair[rng.int(fair.count)]
            if jumpWindow(w: s.w, h: s.h, v: baseSpeed + s.vx) < T.minWindow { windowViolations += 1 }
            _ = add(s.kind, x: x0, w: s.w, h: s.h, vx: s.vx)
            right = x0 + s.w
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
                let lead = (target - (heroX + T.bodyW / 2)) / speed
                let clear = !things.contains { ($0.isHazard || $0.kind == .pit || $0.kind == .sign) && abs(($0.x + $0.w / 2) - target) < speed * 0.9 }
                if lead >= max(1.6, 1.15 + 0.6) && clear && jumpWindow(w: 9, h: 8, v: speed) >= T.minWindow {          // >= 1.6 s when scheduled, >= 0.6 s left after landing
                    b.stage = .telegraph; b.t = 0; b.targetX = target
                    lastRight = max(lastRight, target + 9)          // generator keeps a full gap after the trap
                    gapLeft = max(gapLeft, (target + 9 - (worldW + 4)) + speed * T.recoveryGap)
                } else {
                    balloonCancels += 1; b.stage = .retreat; b.t = 0
                }
            }
        case .telegraph:
            b.x -= move; b.targetX -= move                           // drifts with the ground it marks
            if b.t >= 0.8 {
                let r = add(.fallingTrap, x: b.targetX - 4.5, y: b.y + 2, w: 9, h: 8)
                b.trapID = r.id; b.stage = .drop; b.t = 0; balloonDrops += 1
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
        let front = heroX + T.bodyW / 2
        let ahead = things.filter {
            !$0.gone && (($0.isHazard && !giant && !guarded) || ($0.kind == .pit && !canCross($0.pitType)))
                && $0.x + $0.w > heroX - T.bodyW / 2
        }
        guard let n = ahead.min(by: { $0.x < $1.x }) else { return }
        let v = speed + n.vx
        if n.kind == .pit {
            // Dangerous while the whole body is over water: take off mid-way through the safe window.
            let span = max(0, n.w - T.bodyW), air = v * 2 * T.jumpV / T.gravity
            if (n.x - (heroX - T.bodyW / 2)) <= (air - span) / 2 { buffer = T.buffer }
            return
        }
        guard let (a, b) = timeAbove(n.h + 0.5) else { return }
        if n.x - front - (v * (a + b) / 2 - (n.w + T.bodyW) / 2) <= 0 { buffer = T.buffer }
    }
}
