//
//  DocketPet.swift
//  Dayflow
//
//  The pet in the "Pet catches it" hand-off (DocketHandoffTransition.swift): Clawd or the
//  Codex pet comes up out of the Dock over the Trash, jumps and catches the handed-off card,
//  walks left with it held up, throws it into the app's message box, cheers while the prompt
//  types in, and hops back down into the Dock.
//
//  Ported from the handoff-catch prototype (mac-handoff.js, catchFlight), with its timings
//  and its drawings. The drawings are in Assets.xcassets/DocketPets: Clawd's (from the Claude
//  app's offline game, plus four poses redrawn for the prototype) and the Codex pet's sprite
//  sheet (from the ChatGPT app) with two redrawn poses.
//

import AppKit
import SwiftUI

enum DocketPetKind: String, CaseIterable {
  case clawd
  case codex

  static let defaultsKey = "docketPet"

  static var current: DocketPetKind {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .clawd
  }

  var displayName: String {
    switch self {
    case .clawd: return "Clawd"
    case .codex: return "Codex pet"
    }
  }
}

/// What the pet is doing, which picks its drawing.
enum DocketPetPose {
  /// Arms up: coming up out of the Dock, jumping, or springing off for home.
  case pop
  /// Landing on the Dock after coming up, then settling.
  case land
  case settle
  /// Swaying while it waits for the card.
  case wait
  /// The card held overhead.
  case hold
  /// The card held overhead while walking left.
  case holdLeft
  /// Letting the card go.
  case release
  /// Cheering while the prompt types in.
  case happy
  /// Dropping back into the Dock.
  case dive
}

// MARK: - Drawings

enum DocketPetArt {
  /// Points across either pet's body.
  static let size: CGFloat = 72
  /// How fast the pets move: the catch's times and the drawings' cycles are stretched by it.
  static let tempo = 0.75

  /// Points to a pixel of Clawd's drawings (its body is 24 across).
  private static let clawdPixel = size / 24
  /// Points to a pixel of the Codex pet's sheet (its body is 144 across).
  private static let codexPixel = size / 144

  struct Metrics {
    /// How far above its feet its raised hands are, where the card rests.
    let hands: CGFloat
    /// Its legs, below its body. When it bobs, its body sinks onto them.
    let legs: CGFloat
    /// How far its body sinks as it bobs.
    let dip: CGFloat
    /// Its height at most, so it can hide under the Dock.
    let tall: CGFloat
  }

  static func metrics(_ kind: DocketPetKind) -> Metrics {
    switch kind {
    case .clawd:
      return Metrics(
        hands: 20 * clawdPixel, legs: 4 * clawdPixel, dip: 1 * clawdPixel, tall: 20 * clawdPixel)
    case .codex:
      return Metrics(
        hands: 170 * codexPixel, legs: 20 * codexPixel, dip: 8 * codexPixel, tall: 170 * codexPixel)
    }
  }

  /// The drawing for `pose`, `ms` into it (its cycles run at the pet's tempo).
  static func drawing(_ kind: DocketPetKind, pose: DocketPetPose, ms: Double) -> String {
    switch kind {
    case .clawd: return clawdDrawing(pose, ms)
    case .codex: return codexDrawing(pose, ms)
    }
  }

  /// Where a drawing goes, relative to the pet's feet: every drawing is pinned by its feet,
  /// so they all stand in the same place.
  static func rect(_ kind: DocketPetKind, drawing: String) -> CGRect {
    switch kind {
    case .clawd: return clawdRect(drawing)
    case .codex: return codexRect(drawing)
    }
  }

  @MainActor
  static func image(_ kind: DocketPetKind, drawing: String) -> Image? {
    switch kind {
    case .clawd:
      return Image(clawdAsset(drawing)).interpolation(.none)
    case .codex:
      if drawing == "hold-plain" { return Image("pose-codex-hands-up-default") }
      if drawing == "hold-left" { return Image("pose-codex-hands-up-left") }
      return codexCell(drawing).map { Image(decorative: $0, scale: 1) }
    }
  }

  /// Draws the pet with its feet at `feet`. When it bobs, its body (above its legs) sinks
  /// `dip` onto its legs while its feet stay put.
  static func draw(
    _ image: Image, rect: CGRect, metrics: Metrics, feet: CGPoint, dip: CGFloat,
    in context: inout GraphicsContext
  ) {
    var base = context
    base.translateBy(x: feet.x, y: feet.y)
    guard dip != 0 else {
      base.draw(image, in: rect)
      return
    }
    let far: CGFloat = 400
    var legs = base
    legs.clip(to: Path(CGRect(x: -far, y: -metrics.legs, width: 2 * far, height: far)))
    legs.draw(image, in: rect)
    var body = base
    body.translateBy(x: 0, y: dip)
    body.clip(to: Path(CGRect(x: -far, y: -far, width: 2 * far, height: far - metrics.legs)))
    body.draw(image, in: rect)
  }

  // MARK: Clawd

  /// Each animation's canvas (width, height) and the middle of its standing body across it,
  /// in pixels of the drawing.
  private static let clawdCanvas: [String: (width: CGFloat, height: CGFloat, middle: CGFloat)] = [
    "jumping": (24, 30, 12), "run": (25, 17, 12), "sway": (28, 17, 14), "walk": (24, 18, 12),
    "excited": (24, 17, 12),
  ]
  /// The jump's drawings go up their canvas as it leaves the ground: where each one's feet are.
  private static let clawdJumpFoot: [String: CGFloat] = [
    "00": 30, "04": 30, "05": 27, "06": 21, "07": 20, "08": 20, "09": 20, "10": 21, "12": 24,
    "13": 30, "14": 30, "16": 30,
  ]
  private static let clawdSway = frames(
    "sway", [4, 6, 8, 10, 13, 15, 17, 19, 22, 24, 26, 28, 31, 33, 35, 37, 40, 42, 44])
  private static let clawdArmsUp = frames("jumping", [6, 7, 8, 9])
  /// Excited (the game's, landing with a mission item): a crouch, then ^ ^ eyes and its arms
  /// up, wiggling.
  private static let clawdExcitedIn: [(String, Double)] = [("excited-02", 71), ("excited-03", 143)]
  private static let clawdExcited = frames("excited", Array(5...20))
  /// Holding the card up, its face goes happy, plain, happy, …
  private static let clawdHold: [(String, Double)] = [("hold-happy", 700), ("jumping-07", 350)]

  private static func clawdDrawing(_ pose: DocketPetPose, _ ms: Double) -> String {
    switch pose {
    case .pop: return "jumping-05"
    case .hold, .holdLeft: return timed(clawdHold, ms)  // both arms straight up, facing front
    case .dive: return cycle(clawdArmsUp, fps: 12, ms)
    case .release: return "jumping-10"
    case .land: return "jumping-13"
    case .settle: return "jumping-14"
    case .wait: return cycle(clawdSway, fps: 12, ms)
    case .happy:
      return ms < 214 ? timed(clawdExcitedIn, ms) : cycle(clawdExcited, fps: 14, ms - 214)
    }
  }

  /// The redrawn poses (hands up with ^ ^ eyes, and the jump's take-off and landing with its
  /// usual eyes) replace the game's.
  private static func clawdAsset(_ drawing: String) -> String {
    if drawing == "hold-happy" { return "pose-clawd-hands-up-happy" }
    if ["jumping-05", "jumping-13", "jumping-14"].contains(drawing) {
      return "pose-clawd-\(drawing)"
    }
    return "clawd-\(drawing)"
  }

  private static func clawdRect(_ drawing: String) -> CGRect {
    let parts =
      drawing == "hold-happy" ? ["jumping", "07"] : drawing.split(separator: "-").map(String.init)
    let canvas = clawdCanvas[parts[0]] ?? (24, 30, 12)
    let foot = parts[0] == "jumping" ? (clawdJumpFoot[parts[1]] ?? canvas.height) : canvas.height
    return CGRect(
      x: -canvas.middle * clawdPixel, y: -foot * clawdPixel,
      width: canvas.width * clawdPixel, height: canvas.height * clawdPixel)
  }

  // MARK: Codex pet

  /// The sheet is 8 columns by 11 rows of 192 × 208 cells. Standing, the pet's feet are at
  /// 200 in its cell; the jump's are higher, and so are the redrawn hands-up poses'.
  private static let codexFoot: [String: CGFloat] = [
    "4-1": 188, "4-2": 178, "4-3": 190, "8-2": 178, "hold-plain": 178, "hold-left": 178,
  ]
  /// Hand on chin.
  private static let codexWait = cells(row: 6, count: 6, each: 150, last: 260)
  /// Its "review" row: ^ ^ eyes and two small hops, pinned to the cell's foot so they leave
  /// the ground (the "h" in front keeps them apart from the hold pose in the same row).
  private static let codexHappy = cells(row: 8, count: 6, each: 150, last: 280).map {
    ("h\($0.0)", $0.1)
  }
  /// The happy hop's peak, both hands raised, and the same with its plain face.
  private static let codexHold: [(String, Double)] = [("8-2", 700), ("hold-plain", 350)]

  private static func codexDrawing(_ pose: DocketPetPose, _ ms: Double) -> String {
    switch pose {
    case .pop: return "4-1"
    case .hold: return timed(codexHold, ms)
    case .holdLeft: return "hold-left"
    case .dive: return "4-2"
    case .release: return "4-3"
    case .land: return "4-4"
    case .settle: return "4-0"
    case .wait: return timed(codexWait, ms)
    case .happy: return timed(codexHappy, ms)
    }
  }

  private static func codexRect(_ drawing: String) -> CGRect {
    let foot = codexFoot[drawing] ?? 200
    return CGRect(
      x: -96 * codexPixel, y: -foot * codexPixel, width: 192 * codexPixel, height: 208 * codexPixel)
  }

  @MainActor private static let codexSheet: CGImage? = NSImage(named: "codex-spritesheet")?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)
  @MainActor private static var codexCells: [String: CGImage] = [:]

  /// One cell of the sheet, like "4-1" (row 4, column 1).
  @MainActor
  private static func codexCell(_ drawing: String) -> CGImage? {
    if let cell = codexCells[drawing] { return cell }
    let numbers = drawing.replacingOccurrences(of: "h", with: "").split(separator: "-").compactMap {
      Int($0)
    }
    guard numbers.count == 2, let sheet = codexSheet else { return nil }
    let scale = CGFloat(sheet.width) / (8 * 192)
    let rect = CGRect(
      x: CGFloat(numbers[1]) * 192 * scale, y: CGFloat(numbers[0]) * 208 * scale,
      width: 192 * scale, height: 208 * scale)
    let cell = sheet.cropping(to: rect)
    codexCells[drawing] = cell
    return cell
  }

  // MARK: Helpers

  private static func frames(_ animation: String, _ numbers: [Int]) -> [String] {
    numbers.map { String(format: "%@-%02d", animation, $0) }
  }

  private static func cells(row: Int, count: Int, each: Double, last: Double) -> [(String, Double)]
  {
    (0..<count).map { ("\(row)-\($0)", $0 == count - 1 ? last : each) }
  }

  /// Round and round `list` at `fps` drawings a second.
  private static func cycle(_ list: [String], fps: Double, _ ms: Double) -> String {
    let index = Int((max(ms, 0) * fps / 1000).rounded(.down))
    return list[index % list.count]
  }

  /// Round and round `list`, each drawing shown for its own time in ms.
  private static func timed(_ list: [(String, Double)], _ ms: Double) -> String {
    let total = list.reduce(0) { $0 + $1.1 }
    var at = ms.truncatingRemainder(dividingBy: total)
    if at < 0 { at += total }
    for (drawing, duration) in list {
      at -= duration
      if at < 0 { return drawing }
    }
    return list[0].0
  }
}

// MARK: - The catch

/// The whole catch worked out ahead, as functions of time: where the pet's feet are, which
/// drawing it shows, and where the card is. Times are ms from the fingers lifting; the
/// pet's are the prototype's, stretched to its tempo. Points are the overlay's.
struct DocketCatchPlan {
  struct CardPlace {
    let center: CGPoint
    let tilt: Double
    let scale: CGFloat
    let opacity: Double
  }

  /// How much longer the pet's moves take at its tempo than at 1.
  static let slow = 1 / DocketPetArt.tempo
  /// How long each bob takes while it waits, the card held up.
  static let bobTime = 600 * slow

  let kind: DocketPetKind
  let metrics: DocketPetArt.Metrics

  /// The card where the fingers left it: its middle, size and drag tilt.
  let cardStart: CGPoint
  let cardSize: CGSize
  let startTilt: Double
  /// The card's scale while the pet holds it: 280 points wide.
  let heldScale: CGFloat
  /// The top of the Dock, where the pet stands, and where its feet are out of sight below it.
  let ground: CGFloat
  let hidden: CGFloat
  /// Where it comes up (over the Trash) and where it walks to with the card.
  let comeUpX: CGFloat
  let walkToX: CGFloat
  /// The message box's middle and the card's scale there. Set once the box is found,
  /// before the throw.
  var target = CGPoint.zero
  var targetScale: CGFloat = 1

  // When each part happens
  let appear: Double
  let rise: Double
  let takeoff: Double
  let caught: Double
  let peak: Double
  let landed: Double
  /// The pet holds here, bobbing, until the app's window is up (`DocketCatchRun.resume`).
  let walk: Double
  let stop: Double
  let throwAt: Double
  let land: Double
  let homeFrom: Double
  let home: Double
  let end: Double

  // Distances, in points
  private static let leap: CGFloat = 120  // the jump, up off the Dock
  private static let arcRise: CGFloat = 150  // the card's flight out, and the throw, go up
  private static let stepTime = 270 * slow  // each step as it walks
  private static let stepBob: CGFloat = 5  // it rises with each step

  init(
    kind: DocketPetKind, card: CGRect, tilt: Double, ground: CGFloat, trashX: CGFloat,
    dockLeft: CGFloat, dockRight: CGFloat, screenWidth: CGFloat, typingMs: Double
  ) {
    let slow = Self.slow
    self.kind = kind
    metrics = DocketPetArt.metrics(kind)
    cardStart = CGPoint(x: card.midX, y: card.midY)
    cardSize = card.size
    startTilt = tilt
    heldScale = min(280 / max(card.width, 1), 1)
    self.ground = ground
    hidden = ground + metrics.tall + 8

    // It comes up over the Trash, and walks out to the right of the card's start, over the
    // Dock, left of where it came up (and further left, as Claude opens on top).
    comeUpX = min(trashX, dockRight - 40, screenWidth - 60)
    let outward = max(cardStart.x + max(260, screenWidth * 0.28), dockLeft + 50)
    walkToX = max(dockLeft + 50, min(outward, dockRight - 50, screenWidth - 90, comeUpX - 80) - 120)

    appear = 72 * slow
    rise = 216 * slow
    takeoff = 504 * slow
    caught = 744 * slow
    peak = 792 * slow
    landed = peak + (peak - takeoff)
    walk = 1128 * slow
    let walking = max(250 * slow, Double(comeUpX - walkToX) / (0.28 * DocketPetArt.tempo))
    stop = walk + walking
    throwAt = stop + 120 * slow
    land = throwAt + 504
    // It stays, happy, while the prompt types in (from just before the card's in), then goes.
    homeFrom = max(throwAt + 240 * slow, land - 60 + typingMs + 250)
    home = homeFrom + 700 * slow
    end = home + 120
  }

  // MARK: The pet

  func petX(at ms: Double) -> CGFloat {
    DocketMotion.mix(comeUpX, walkToX, Self.smooth((ms - walk) / (stop - walk)))
  }

  /// Its feet: up out of the Dock; a jump that tops out just after the catch; back on the
  /// Dock, a little rise each step as it walks; after the throw, a hop and back down into it.
  func feetY(at ms: Double) -> CGFloat {
    if ms < takeoff {
      let v = Self.clamp((ms - appear) / rise)
      return DocketMotion.mix(hidden, ground, 1 - pow(1 - v, 3))
    }
    if ms < landed {
      let v = (ms - peak) / (peak - takeoff)
      return ground - Self.leap * CGFloat(1 - v * v)
    }
    if ms >= walk && ms < stop {
      return ground - Self.stepBob * CGFloat(abs(sin(.pi * (ms - walk) / Self.stepTime)))
    }
    if ms < homeFrom { return ground }
    return ground
      + Self.hopDown(Self.clamp((ms - homeFrom) / (home - homeFrom)), depth: hidden - ground)
  }

  /// The pose at story time `ms`. `wall` keeps the held card's faces going while the story
  /// waits; `waiting` is true while it holds for the app's window.
  func pose(at ms: Double, wall: Double, waiting: Bool) -> (pose: DocketPetPose, ms: Double) {
    let slow = Self.slow
    let tempo = DocketPetArt.tempo
    func before(_ from: Double, _ n: Double) -> Bool { ms < from + n * slow }

    if waiting { return (.hold, wall - caught) }
    if before(appear, 144) { return (.pop, 0) }
    if before(appear, 192) { return (.land, 0) }
    if before(appear, 240) { return (.settle, 0) }
    if before(takeoff, -72) { return (.wait, (ms - appear - 240 * slow) * tempo) }
    if ms < takeoff { return (.land, 0) }
    if ms < caught { return (.pop, 0) }
    if ms >= walk && ms < stop { return (.holdLeft, wall - caught) }
    if ms < throwAt { return (.hold, wall - caught) }
    if before(throwAt, 72) { return (.release, 0) }
    if ms < homeFrom { return (.happy, (ms - throwAt - 72 * slow) * tempo) }
    if before(homeFrom, 0.32 * 700) { return (.pop, 0) }
    return (.dive, ms * tempo)
  }

  // MARK: The card

  /// The middle of the card resting on the pet's raised hands.
  private func onHands(at ms: Double, dip: CGFloat) -> CGPoint {
    CGPoint(
      x: petX(at: ms), y: feetY(at: ms) + dip - metrics.hands + 2 - cardSize.height * heldScale / 2)
  }

  /// Out, up and over, falling into its hands; held there; thrown up and over into the box,
  /// growing to its width; then sinking in and fading. Nil once it's gone.
  func card(at ms: Double, dip: CGFloat) -> CardPlace? {
    if ms < caught {
      let v = ms / caught
      let caughtAt = onHands(at: caught, dip: 0)
      let top = CGPoint(
        x: DocketMotion.mix(cardStart.x, comeUpX, 0.5),
        y: min(cardStart.y, caughtAt.y) - 2 * Self.arcRise)
      return CardPlace(
        center: Self.arc(cardStart, top, caughtAt, v),
        tilt: startTilt + (0 - startTilt) * Double(Self.smooth(v)) + 8 * Self.bump(v),
        scale: DocketMotion.mix(1, heldScale, 1 - pow(1 - v, 3)), opacity: 1)
    }
    if ms < throwAt {
      return CardPlace(center: onHands(at: ms, dip: dip), tilt: 0, scale: heldScale, opacity: 1)
    }
    if ms < land {
      let v = (ms - throwAt) / (land - throwAt)
      let from = onHands(at: throwAt, dip: 0)
      let top = CGPoint(x: (from.x + target.x) / 2, y: min(from.y, target.y) - 2 * Self.arcRise)
      return CardPlace(
        center: Self.arc(from, top, target, v), tilt: -10 * Self.bump(v),
        scale: DocketMotion.mix(heldScale, targetScale, Self.smooth(v)), opacity: 1)
    }
    if ms < land + 120 {
      let v = CGFloat((ms - land) / 120)
      return CardPlace(
        center: CGPoint(x: target.x, y: target.y + 5 * v), tilt: 0,
        scale: DocketMotion.mix(targetScale, targetScale * 0.7, v), opacity: Double(1 - v))
    }
    return nil
  }

  // MARK: Curves

  private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

  private static func smooth(_ v: Double) -> CGFloat {
    let c = clamp(v)
    return CGFloat(c * c * (3 - 2 * c))
  }

  /// 0 at both ends, 1 in the middle.
  private static func bump(_ v: Double) -> Double { v > 0 && v < 1 ? sin(.pi * v) : 0 }

  /// A point on the quadratic curve from `a` through `top` to `b`.
  private static func arc(_ a: CGPoint, _ top: CGPoint, _ b: CGPoint, _ v: Double) -> CGPoint {
    let t = CGFloat(v)
    func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
      CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
    }
    return mix(mix(a, top), mix(top, b))
  }

  /// The hop back into the Dock, `v` 0–1 through it: up a little, easing to a hang at the
  /// top, then falling faster and faster `depth` points. Points from where it stood.
  private static func hopDown(_ v: Double, depth: CGFloat) -> CGFloat {
    let up: CGFloat = 30
    let top = 0.32
    if v < top { return -up * CGFloat(1 - pow(1 - v / top, 3)) }
    return DocketMotion.mix(-up, depth, CGFloat(pow((v - top) / (1 - top), 4)))
  }
}

/// A catch in progress: the plan, and the clock it plays on. The clock holds at the walk,
/// the pet bobbing with the card, until the app's window is up and its message box found.
@MainActor
final class DocketCatchRun {
  struct Moment {
    let feet: CGPoint
    let petOpacity: Double
    let dip: CGFloat
    let drawing: String
    let card: DocketCatchPlan.CardPlace?
  }

  var plan: DocketCatchPlan
  let start: Date
  /// When (wall ms) the story goes on after holding at the walk; nil while it still holds.
  private var resumeAt: Double?

  init(plan: DocketCatchPlan, start: Date) {
    self.plan = plan
    self.start = start
  }

  private func wallMs(at date: Date) -> Double {
    date.timeIntervalSince(start) * 1000
  }

  /// The story's time: wall time, less however long it held at the walk.
  func storyMs(at date: Date) -> Double {
    let wall = wallMs(at: date)
    guard wall > plan.walk else { return wall }
    guard let resumeAt else { return plan.walk }
    return max(plan.walk, wall - (resumeAt - plan.walk))
  }

  /// Lets the story go on past the walk, once the bob it's in is over.
  func resume(at date: Date = Date()) {
    let waited = max(0, wallMs(at: date) - plan.walk)
    resumeAt = plan.walk + (waited / DocketCatchPlan.bobTime).rounded(.up) * DocketCatchPlan.bobTime
  }

  func moment(at date: Date) -> Moment {
    let wall = wallMs(at: date)
    let story = storyMs(at: date)
    let waiting = wall > plan.walk && (resumeAt.map { wall < $0 } ?? true)
    // While it waits, its body sinks a little onto its legs and back, the card held up.
    let since = wall - plan.walk
    let dip =
      waiting
      ? plan.metrics.dip * CGFloat(1 - cos(2 * .pi * since / DocketCatchPlan.bobTime)) / 2 : 0
    let pose = plan.pose(at: story, wall: wall, waiting: waiting)
    return Moment(
      feet: CGPoint(x: plan.petX(at: story), y: plan.feetY(at: story)),
      petOpacity: story < plan.appear ? 0 : 1,
      dip: dip,
      drawing: DocketPetArt.drawing(plan.kind, pose: pose.pose, ms: pose.ms),
      card: plan.card(at: story, dip: dip))
  }
}

// MARK: - Drawing

/// The pet, cut off at the top of the Dock so it comes up out of it and goes back down
/// into it.
struct DocketPetCanvas: View {
  let kind: DocketPetKind
  let drawing: String
  let feet: CGPoint
  let dip: CGFloat
  let ground: CGFloat
  let opacity: Double

  var body: some View {
    let image = DocketPetArt.image(kind, drawing: drawing)
    let rect = DocketPetArt.rect(kind, drawing: drawing)
    let metrics = DocketPetArt.metrics(kind)
    Canvas { context, size in
      guard let image else { return }
      context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: ground)))
      DocketPetArt.draw(image, rect: rect, metrics: metrics, feet: feet, dip: dip, in: &context)
    }
    .opacity(opacity)
  }
}
