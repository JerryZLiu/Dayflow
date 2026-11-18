//
//  FlowAgentSettings.swift
//  Dayflow
//
//  Everything about the Flow companion that we're still tuning, in one
//  UserDefaults-backed object the debug panel (FlowDebugPanel) edits live:
//  which model watches the screen and how hard it thinks, how often it looks,
//  what it's told, and how the overlay behaves.
//

import Combine
import Foundation

@MainActor
final class FlowAgentSettings: ObservableObject {
  static let shared = FlowAgentSettings()

  static let reasoningEfforts = ["none", "minimal", "low", "medium", "high"]
  static let screenshotHeights = [480, 720, 1080]

  // MARK: Agent

  /// Master switch: off means sessions run with no screen watching at all.
  @Published var agentEnabled: Bool { didSet { set(agentEnabled, "flowAgentEnabled") } }
  /// Codex model for every turn (briefing and ticks).
  @Published var model: String { didSet { set(model, "flowAgentModel") } }
  @Published var reasoningEffort: String { didSet { set(reasoningEffort, "flowAgentReasoning") } }
  /// Seconds between screenshots.
  @Published var tickSeconds: Double { didSet { set(tickSeconds, "flowAgentTickSeconds") } }
  /// Screenshot height in pixels (width follows the display's aspect).
  @Published var screenshotHeight: Int { didSet { set(screenshotHeight, "flowAgentShotHeight") } }
  @Published var jpegQuality: Double { didSet { set(jpegQuality, "flowAgentJpegQuality") } }
  /// Consecutive failed turns before the agent gives up for the session.
  @Published var maxFailures: Int { didSet { set(maxFailures, "flowAgentMaxFailures") } }
  /// Per-tick timeout for the Codex process.
  @Published var tickTimeoutSeconds: Double {
    didSet { set(tickTimeoutSeconds, "flowAgentTickTimeout") }
  }
  /// The briefing template; empty means the built-in one. See
  /// FlowDistractionAgent.briefingTemplate for the placeholders.
  @Published var briefingTemplate: String { didSet { set(briefingTemplate, "flowAgentBriefing") } }
  /// Appended to whichever briefing is used, for quick experiments.
  @Published var extraInstructions: String { didSet { set(extraInstructions, "flowAgentExtra") } }
  /// How often a tick also asks the model to revise the session timeline.
  @Published var timelineEverySeconds: Double {
    didSet { set(timelineEverySeconds, "flowAgentTimelineSeconds") }
  }

  // MARK: Overlay

  /// How long the break tub stays before the creature climbs out.
  @Published var breakOverlaySeconds: Double {
    didSet { set(breakOverlaySeconds, "flowBreakOverlaySeconds") }
  }
  @Published var toastSeconds: Double { didSet { set(toastSeconds, "flowToastSeconds") } }
  @Published var praiseSeconds: Double { didSet { set(praiseSeconds, "flowPraiseSeconds") } }
  /// Where the creature comes in, as a drag offset from the default corner:
  /// the side layout moves up/down, the from-above layouts move left/right.
  /// Set by dragging the creature on the desktop.
  @Published var sideOffsetY: Double { didSet { set(sideOffsetY, "flowOverlaySideOffsetY") } }
  @Published var topOffsetX: Double { didSet { set(topOffsetX, "flowOverlayTopOffsetX") } }
  @Published var peekOffsetX: Double { didSet { set(peekOffsetX, "flowOverlayPeekOffsetX") } }
  @Published var nudgeVariant: FlowNudgeVariant {
    didSet {
      if FlowNudgeVariant.current != nudgeVariant { FlowNudgeVariant.current = nudgeVariant }
    }
  }

  private let defaults = UserDefaults.standard

  private init() {
    let d = UserDefaults.standard
    agentEnabled = d.object(forKey: "flowAgentEnabled") as? Bool ?? true
    model = d.string(forKey: "flowAgentModel").flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-6-luna"
    let effort = d.string(forKey: "flowAgentReasoning") ?? "low"
    reasoningEffort = Self.reasoningEfforts.contains(effort) ? effort : "low"
    let tick = d.double(forKey: "flowAgentTickSeconds")
    tickSeconds = tick >= 5 ? tick : 60
    let height = d.integer(forKey: "flowAgentShotHeight")
    screenshotHeight = height >= 240 ? height : 1080
    let quality = d.double(forKey: "flowAgentJpegQuality")
    jpegQuality = quality > 0 ? quality : 0.6
    let failures = d.integer(forKey: "flowAgentMaxFailures")
    maxFailures = failures > 0 ? failures : 3
    let timeout = d.double(forKey: "flowAgentTickTimeout")
    tickTimeoutSeconds = timeout >= 10 ? timeout : 60
    briefingTemplate = d.string(forKey: "flowAgentBriefing") ?? ""
    extraInstructions = d.string(forKey: "flowAgentExtra") ?? ""
    let timelineSeconds = d.double(forKey: "flowAgentTimelineSeconds")
    timelineEverySeconds = timelineSeconds >= 15 ? timelineSeconds : 60
    let breakSeconds = d.double(forKey: "flowBreakOverlaySeconds")
    breakOverlaySeconds = breakSeconds > 0 ? breakSeconds : 8
    let toast = d.double(forKey: "flowToastSeconds")
    toastSeconds = toast > 0 ? toast : 4
    let praise = d.double(forKey: "flowPraiseSeconds")
    praiseSeconds = praise > 0 ? praise : 5
    sideOffsetY = d.double(forKey: "flowOverlaySideOffsetY")
    topOffsetX = d.double(forKey: "flowOverlayTopOffsetX")
    peekOffsetX = d.double(forKey: "flowOverlayPeekOffsetX")
    nudgeVariant = FlowNudgeVariant.current
  }

  /// Drag offset for a layout (x for the from-above layouts, y for side).
  func positionOffset(for variant: FlowNudgeVariant) -> Double {
    switch variant {
    case .side: return sideOffsetY
    case .top: return topOffsetX
    case .peek: return peekOffsetX
    }
  }

  func setPositionOffset(_ value: Double, for variant: FlowNudgeVariant) {
    switch variant {
    case .side: sideOffsetY = value
    case .top: topOffsetX = value
    case .peek: peekOffsetX = value
    }
  }

  func resetPositions() {
    sideOffsetY = 0
    topOffsetX = 0
    peekOffsetX = 0
  }

  private func set(_ value: Any, _ key: String) {
    defaults.set(value, forKey: key)
  }

  /// Back to the built-in values (keeps the nudge variant).
  func resetToDefaults() {
    agentEnabled = true
    model = "gpt-6-luna"
    reasoningEffort = "low"
    tickSeconds = 60
    screenshotHeight = 1080
    jpegQuality = 0.6
    maxFailures = 3
    tickTimeoutSeconds = 60
    briefingTemplate = ""
    extraInstructions = ""
    timelineEverySeconds = 60
    breakOverlaySeconds = 8
    toastSeconds = 4
    praiseSeconds = 5
  }
}
