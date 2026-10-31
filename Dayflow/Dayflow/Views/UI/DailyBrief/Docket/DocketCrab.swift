//
//  DocketCrab.swift
//  Dayflow
//
//  The crab that catches a handed-off card and throws it into the app's message box.
//  It moves like a flipbook, the way Anthropic animates Clawd: whole pixel poses held for
//  one frame each at 12 frames a second, with no easing between them. The card it throws
//  still moves smoothly, so the steppy crab reads as hand-drawn against it.
//
//  PLACEHOLDER ART: the poses below are Clawd-shaped so the motion can be judged. Swap in
//  our own crab before shipping; only the strings in `DocketCrabArt` need to change.
//

import SwiftUI

/// Where the crab is and what it's doing. The director sets `move` and `start`; the
/// overlay picks the frame from how long the move has been running.
struct DocketCrab {
  enum Move {
    /// Rises out of the ground under the card and raises its claws.
    case catching
    /// Bobs with the card overhead while the app comes forward. Loops.
    case holding
    /// Crouches and looks back, away from where it's about to throw.
    case windingUp
    /// Lets go, facing the message box.
    case throwing
    /// A little hop with a wink.
    case cheering
    /// Disappears in a puff of dust.
    case leaving
  }

  var move: Move
  var start: Date
  /// The middle of the crab's feet, in the overlay's coordinates.
  let ground: CGPoint
  /// The poses face right; mirrored when the message box is to the left.
  var facesLeft = false

  func frame(at date: Date) -> DocketCrabArt.Frame {
    let frames = DocketCrabArt.frames(for: move)
    let index = Int(max(date.timeIntervalSince(start), 0) * DocketCrabArt.fps)
    return move == .holding ? frames[index % frames.count] : frames[min(index, frames.count - 1)]
  }
}

// MARK: - Art

enum DocketCrabArt {
  static let fps = 12.0
  /// Seconds per frame.
  static let frameTime = 1 / fps
  /// Points per art pixel.
  static let pixel: CGFloat = 5
  static let width = 16
  static let height = 10
  /// Room above the poses for hops.
  static let headroom = 4

  /// One frame: a pose (nil draws nothing) lifted `dy` art pixels (negative is up).
  struct Frame {
    let pose: [String]?
    let dy: Int
  }

  /// B is the body, E the eyes, P a puff of dust, anything else is empty.
  static let colors: [Character: Color] = [
    "B": Color(hex: "D97757"),
    "E": Color(hex: "141413"),
    "P": Color(hex: "C9C3B6"),
  ]

  static let stand = [
    "................",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BBEBBBBBBEBB..",
    "BBBBEBBBBBBEBBBB",
    "BBBBBBBBBBBBBBBB",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..B.B......B.B..",
    "..B.B......B.B..",
  ]

  static let clawsUp = [
    "B..............B",
    "B.BBBBBBBBBBBB.B",
    "BBBBBBBBBBBBBBBB",
    "..BBEBBBBBBEBB..",
    "..BBEBBBBBBEBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..B.B......B.B..",
    "..B.B......B.B..",
  ]

  static let clawsUpBlink = [
    "B..............B",
    "B.BBBBBBBBBBBB.B",
    "BBBBBBBBBBBBBBBB",
    "..BBBBBBBBBBBB..",
    "..BEEBBBBBBEEB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..B.B......B.B..",
    "..B.B......B.B..",
  ]

  /// Claws up, eyes looking left: back over its shoulder before a throw to the right.
  static let lookBack = [
    "B..............B",
    "B.BBBBBBBBBBBB.B",
    "BBBBBBBBBBBBBBBB",
    "..BEBBBBBBEBBB..",
    "..BEBBBBBBEBBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..B.B......B.B..",
    "..B.B......B.B..",
  ]

  /// Claws flung forward to the right, eyes following the card.
  static let release = [
    "................",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBBBB",
    "..BBBBBEBBBBBEBB",
    "BBBBBBBEBBBBBEBB",
    "BBBBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..B.B......B.B..",
    "..B.B......B.B..",
  ]

  static let wink = [
    "B..............B",
    "B.BBBBBBBBBBBB.B",
    "BBBBBBBBBBBBBBBB",
    "..BBEBBBBBBBBB..",
    "..BBEBBBBBBEEB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..B.B......B.B..",
    "..B.B......B.B..",
  ]

  static let dust = [
    "................",
    "..BBBBBBBBBBBB..",
    "..BBBBBBBBBBBB..",
    "..BEEBBBBBBEEB..",
    "BBBBBBBBBBBBBBBB",
    "BBBBBBBBBBBBBBBB",
    "..BBBBBBBBBBBB..",
    "P.BBBBBBBBBBBB.P",
    "PPB.B......B.BPP",
    "P.B.B......B.B.P",
  ]

  static let puff = [
    "................",
    "................",
    ".....PP..PP.....",
    "...PPPPPPPPPP...",
    "..PPPPPPPPPPPP..",
    "..PPPPPPPPPPPP..",
    "...PPPPPPPPPP...",
    "....PP.PP.PP....",
    "................",
    "................",
  ]

  static let puffFading = [
    "................",
    "................",
    "....P......P....",
    "................",
    "..P....PP....P..",
    "................",
    "....P......P....",
    "................",
    "................",
    "................",
  ]

  static func frames(for move: DocketCrab.Move) -> [Frame] {
    switch move {
    case .catching:
      // Rises out of the ground (below the ground line is clipped), then claws up.
      return [
        Frame(pose: stand, dy: 9), Frame(pose: stand, dy: 5), Frame(pose: stand, dy: 1),
        Frame(pose: clawsUp, dy: -2), Frame(pose: clawsUp, dy: 0),
      ]
    case .holding:
      // A two-step bob, two frames each, with a blink near the end of every loop (2s).
      var frames: [Frame] = []
      for step in 0..<24 {
        let pose = step == 20 || step == 21 ? clawsUpBlink : clawsUp
        // Bobs up, not down: anything below the ground is cut off, which would hide its legs.
        frames.append(Frame(pose: pose, dy: -((step / 2) % 2)))
      }
      return frames
    case .windingUp:
      // A one-pixel crouch: the ground cuts the bottom of its legs, so they look bent.
      return [Frame(pose: lookBack, dy: 1), Frame(pose: lookBack, dy: 1), Frame(pose: lookBack, dy: 1)]
    case .throwing:
      return [Frame(pose: release, dy: -1), Frame(pose: release, dy: 0), Frame(pose: stand, dy: 0)]
    case .cheering:
      return [
        Frame(pose: wink, dy: -3), Frame(pose: wink, dy: -3), Frame(pose: wink, dy: -1),
        Frame(pose: clawsUp, dy: 0), Frame(pose: clawsUp, dy: 0),
      ]
    case .leaving:
      return [
        Frame(pose: dust, dy: 0), Frame(pose: puff, dy: 0), Frame(pose: puff, dy: -1),
        Frame(pose: puffFading, dy: -1), Frame(pose: nil, dy: 0),
      ]
    }
  }

  /// How long a move takes before it settles on its last frame.
  static func duration(of move: DocketCrab.Move) -> Double {
    Double(frames(for: move).count) * frameTime
  }
}

// MARK: - Drawing

/// One frame of the crab, standing on `crab.ground`. Anything below the ground is cut off,
/// which is how it rises out of the floor.
struct DocketCrabSprite: View {
  let frame: DocketCrabArt.Frame
  let facesLeft: Bool

  private static let size = CGSize(
    width: CGFloat(DocketCrabArt.width) * DocketCrabArt.pixel,
    height: CGFloat(DocketCrabArt.height + DocketCrabArt.headroom) * DocketCrabArt.pixel)

  var body: some View {
    Canvas { context, _ in
      guard let pose = frame.pose else { return }
      let pixel = DocketCrabArt.pixel
      let top = DocketCrabArt.headroom + frame.dy
      for (row, line) in pose.enumerated() {
        for (column, character) in line.enumerated() {
          guard let color = DocketCrabArt.colors[character] else { continue }
          let rect = CGRect(
            x: CGFloat(column) * pixel, y: CGFloat(top + row) * pixel, width: pixel, height: pixel)
          context.fill(Path(rect), with: .color(color))
        }
      }
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .clipped()
    .scaleEffect(x: facesLeft ? -1 : 1, y: 1)
  }

  /// Where the sprite's box goes so its feet sit on `ground`.
  static func box(standingOn ground: CGPoint) -> CGRect {
    CGRect(x: ground.x - size.width / 2, y: ground.y - size.height, width: size.width, height: size.height)
  }

  /// The top of the raised claws, where a held card rests.
  static func clawTop(standingOn ground: CGPoint) -> CGFloat {
    ground.y - CGFloat(DocketCrabArt.height) * DocketCrabArt.pixel
  }
}

// MARK: - Thrown card

/// The card in the crab style. At progress 0 it sits at `from` (held, or still in the
/// deck); as progress runs to 1 it flies along an arc into `to`, spinning a little and
/// fading out as it goes in.
struct DocketThrownCard<Card: View>: View, Animatable {
  var progress: Double
  let from: CGRect
  let to: CGRect
  let tilt: Double
  /// The card's size as the deck drew it; `card` is laid out at this size, then scaled.
  let base: CGSize
  let screenSize: CGSize
  let card: Card

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let p = progress
    // A quadratic curve whose middle point sits well above both ends.
    let peakX = Double(from.midX + to.midX) / 2
    let peakY = Double(min(from.midY, to.midY)) - 160
    let center = CGPoint(
      x: Self.curve(Double(from.midX), peakX, Double(to.midX), p),
      y: Self.curve(Double(from.midY), peakY, Double(to.midY), p))
    let width = DocketMotion.mix(from.width, to.width, p)
    let spin = sin(p * .pi) * (to.midX < from.midX ? -14 : 14)
    card
      .frame(width: base.width, height: base.height)
      .scaleEffect(width / max(base.width, 1))
      .rotationEffect(.degrees(DocketMotion.mix(tilt, 0, p) + spin))
      .opacity(p > 0.8 ? max(0, (1 - p) / 0.2) : 1)
      .position(center)
      .frame(width: screenSize.width, height: screenSize.height)
  }

  /// A point on the quadratic curve from `start` through `control` to `end`.
  private static func curve(_ start: Double, _ control: Double, _ end: Double, _ t: Double) -> Double {
    let rest = 1 - t
    return rest * rest * start + 2 * rest * t * control + t * t * end
  }
}
