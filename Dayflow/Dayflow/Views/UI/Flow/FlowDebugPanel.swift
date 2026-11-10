//
//  FlowDebugPanel.swift
//  Dayflow
//
//  Bottom-left "Debug" button on the Flow tab. Opens a dark card with the
//  agent transcript and every knob in FlowAgentSettings, plus buttons that
//  bring the creature in on demand (side / top / peek), so the whole
//  companion can be tuned without rebuilding.
//

import SwiftUI

struct FlowDebugPanel: View {
  @ObservedObject private var agent = FlowDistractionAgent.shared
  @ObservedObject private var settings = FlowAgentSettings.shared
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @ObservedObject private var timeline = FlowSessionTimeline.shared
  @State private var isOpen = false
  @State private var tab: Tab = .log
  @State private var toastText = "Nice streak, keep it up!"
  @State private var showBriefing = false

  private enum Tab: String, CaseIterable {
    case log = "Log"
    case agent = "Agent"
    case prompt = "Prompt"
    case overlay = "Overlay"
    case timeline = "Timeline"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Spacer()
      if isOpen {
        panel
      }
      Button(isOpen ? "Hide debug" : "Debug (\(agent.transcript.count))") {
        isOpen.toggle()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .medium))
      .foregroundColor(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Capsule().fill(Color.black.opacity(0.6)))
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        ForEach(Tab.allCases, id: \.self) { entry in
          Button(entry.rawValue) { tab = entry }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: tab == entry ? .semibold : .regular))
            .foregroundColor(tab == entry ? .black : .white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tab == entry ? Color.white : Color.white.opacity(0.12)))
        }
        Spacer()
        statusBadge
      }
      Group {
        switch tab {
        case .log: logList
        case .agent: agentForm
        case .prompt: promptForm
        case .overlay: overlayForm
        case .timeline: timelineList
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(10)
    .frame(width: 520, height: 400)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
    .foregroundColor(.white)
    .tint(.white)
  }

  private var statusBadge: some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(agent.statusLine)
        .font(.system(size: 10, weight: .medium))
      if let at = agent.lastTickAt {
        Text(
          verbatim:
            "last tick " + at.formatted(.dateTime.hour().minute().second())
            + (agent.lastTickSeconds.map { String(format: " · %.1fs", $0) } ?? "")
        )
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.white.opacity(0.6))
      }
    }
  }

  // MARK: Log

  private var logList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if agent.transcript.isEmpty {
              Text("No agent output yet.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            }
            ForEach(agent.transcript) { entry in
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                  .font(.system(size: 9, design: .monospaced))
                  .foregroundColor(.white.opacity(0.5))
                Text(entry.text)
                  .font(.system(size: 11, design: .monospaced))
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .id(entry.id)
            }
          }
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: agent.transcript) {
          if let last = agent.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        .onAppear {
          if let last = agent.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
      HStack(spacing: 8) {
        smallButton("Tick now") { agent.tickNow() }
        smallButton("Restart agent") { agent.restart() }
        smallButton("Clear") { agent.clearTranscript() }
      }
    }
  }

  // MARK: Agent

  private var agentForm: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Watch the screen during sessions", isOn: $settings.agentEnabled)
          .font(.system(size: 11))
        row("Model") {
          TextField("gpt-6-astra", text: $settings.model)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
        }
        row("Reasoning") {
          Picker("", selection: $settings.reasoningEffort) {
            ForEach(FlowAgentSettings.reasoningEfforts, id: \.self) { Text($0) }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        slider(
          "Every \(Int(settings.tickSeconds))s", value: $settings.tickSeconds, in: 5...120, step: 5)
        slider(
          "Timeline every \(Int(settings.timelineEverySeconds))s",
          value: $settings.timelineEverySeconds, in: 15...300, step: 15)
        row("Screenshot") {
          Picker("", selection: $settings.screenshotHeight) {
            ForEach(FlowAgentSettings.screenshotHeights, id: \.self) { Text("\($0)p") }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        slider(
          String(format: "JPEG quality %.2f", settings.jpegQuality), value: $settings.jpegQuality,
          in: 0.3...0.95, step: 0.05
        )
        .font(.system(size: 11))
        slider(
          "Turn timeout \(Int(settings.tickTimeoutSeconds))s", value: $settings.tickTimeoutSeconds,
          in: 10...180, step: 5)
        Stepper(
          "Give up after \(settings.maxFailures) failed turns", value: $settings.maxFailures,
          in: 1...20
        )
        .font(.system(size: 11))
        Text(
          "Model, reasoning, prompt, and screenshot changes take effect on the next tick for a running agent, except the model and prompt, which need Restart agent."
        )
        .font(.system(size: 10))
        .foregroundColor(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          smallButton("Restart agent") { agent.restart() }
          smallButton("Reset to defaults") { settings.resetToDefaults() }
        }
      }
      .padding(4)
    }
  }

  // MARK: Prompt

  private var promptForm: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(showBriefing ? "Briefing as it would be sent now" : "Briefing template")
          .font(.system(size: 11, weight: .semibold))
        Spacer()
        smallButton(showBriefing ? "Edit template" : "Preview") { showBriefing.toggle() }
        smallButton("Use built-in") {
          settings.briefingTemplate = ""
        }
        smallButton("Copy built-in into editor") {
          settings.briefingTemplate = FlowDistractionAgent.briefingTemplate
        }
      }
      if showBriefing {
        ScrollView {
          Text(agent.currentBriefing)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
      } else {
        TextEditor(text: $settings.briefingTemplate)
          .font(.system(size: 10, design: .monospaced))
          .scrollContentBackground(.hidden)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
          .overlay(alignment: .topLeading) {
            if settings.briefingTemplate.isEmpty {
              Text(
                "Empty = built-in. Placeholders: {{started}} {{length}} {{style}} {{goals}} {{style_rules}} {{tick_seconds}} {{timeline_mechanics}}"
              )
              .font(.system(size: 10))
              .foregroundColor(.white.opacity(0.45))
              .padding(8)
              .allowsHitTesting(false)
            }
          }
      }
      Text("Extra instructions (appended)")
        .font(.system(size: 11, weight: .semibold))
      TextEditor(text: $settings.extraInstructions)
        .font(.system(size: 10, design: .monospaced))
        .scrollContentBackground(.hidden)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
      HStack {
        Text("Prompt changes apply on Restart agent (a new conversation).")
          .font(.system(size: 10))
          .foregroundColor(.white.opacity(0.6))
        Spacer()
        smallButton("Restart agent") { agent.restart() }
      }
    }
  }

  // MARK: Overlay

  private var overlayForm: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        row("Nudge layout") {
          Picker("", selection: $settings.nudgeVariant) {
            ForEach(FlowNudgeVariant.allCases, id: \.self) { Text($0.title) }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        Text("Trigger now")
          .font(.system(size: 11, weight: .semibold))
        HStack(spacing: 8) {
          smallButton("Nudge from side") { mirror.debugNudge(variant: .side) }
          smallButton("Drop from top") { mirror.debugNudge(variant: .top) }
          smallButton("Peek from top") { mirror.debugNudge(variant: .peek) }
        }
        HStack(spacing: 8) {
          smallButton("Escalated (fire)") { mirror.debugNudge(variant: .side, escalated: true) }
          smallButton("Break tub") { mirror.debugBreak() }
          smallButton("Dismiss") { mirror.debugHideOverlay() }
          smallButton("Simulate distraction (⌘⇧D)") { mirror.simulateDistraction() }
        }
        HStack(spacing: 8) {
          TextField("Toast text", text: $toastText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
          smallButton("Show toast") { mirror.debugToast(toastText) }
        }
        Divider().overlay(Color.white.opacity(0.2))
        slider(
          "Break tub stays \(Int(settings.breakOverlaySeconds))s",
          value: $settings.breakOverlaySeconds,
          in: 2...60, step: 1)
        slider(
          "Toasts stay \(Int(settings.toastSeconds))s", value: $settings.toastSeconds, in: 1...20,
          step: 1)
        slider(
          "Praise stays \(Int(settings.praiseSeconds))s", value: $settings.praiseSeconds,
          in: 1...20, step: 1)
        HStack(spacing: 8) {
          Text(
            String(
              format: "Drag offsets: side %.0f · top %.0f · peek %.0f", settings.sideOffsetY,
              settings.topOffsetX, settings.peekOffsetX)
          )
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.white.opacity(0.7))
          smallButton("Reset positions") {
            settings.resetPositions()
            FlowOverlayController.shared.repositionIfVisible()
          }
        }
        Text(
          "Hover the creature to reveal its bubble and replies; drag it to move where it comes from (side: up/down, top layouts: left/right). Simulate distraction needs an active session; the trigger buttons above work any time."
        )
        .font(.system(size: 10))
        .foregroundColor(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(4)
    }
  }

  // MARK: Timeline

  /// The activity timeline the agent is building for the session summary,
  /// straight from FlowSessionTimeline (what the JSON file holds right now).
  private var timelineList: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(verbatim: timeline.fileURL.path)
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(.white.opacity(0.6))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if let at = timeline.updatedAt {
          Text(verbatim: "updated " + at.formatted(.dateTime.hour().minute().second()))
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
        }
        smallButton("Update now") { agent.requestTimelineNow() }
        smallButton("Reveal") {
          NSWorkspace.shared.activateFileViewerSelecting([timeline.fileURL])
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          if timeline.entries.isEmpty {
            Text(
              verbatim:
                "No timeline yet. The model writes one about every "
                + "\(Int(settings.timelineEverySeconds))s of a session "
                + "(\(timeline.observations.count) checks logged so far)."
            )
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.6))
          }
          ForEach(timeline.entries) { entry in
            HStack(alignment: .top, spacing: 8) {
              Text(
                verbatim:
                  entry.startedAt.formatted(.dateTime.hour().minute()) + "–"
                  + entry.endedAt.formatted(.dateTime.hour().minute())
              )
              .font(.system(size: 10, design: .monospaced))
              .foregroundColor(.white.opacity(0.6))
              .frame(width: 96, alignment: .leading)
              RoundedRectangle(cornerRadius: 2)
                .fill(timelineColor(entry.kind))
                .frame(width: 6, height: 14)
              Text(verbatim: entry.title)
                .font(.system(size: 11))
              Spacer()
              Text(verbatim: Self.duration(entry.endedAt.timeIntervalSince(entry.startedAt)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func timelineColor(_ kind: FlowSessionTimeline.Kind) -> Color {
    switch kind {
    case .focused: return Color(red: 0.36, green: 0.76, blue: 1.0)
    case .distracted: return Color(red: 1.0, green: 0.55, blue: 0.4)
    case .break: return Color.white.opacity(0.4)
    }
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
  }

  // MARK: Bits

  private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View
  {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11))
        .frame(width: 80, alignment: .leading)
      content()
    }
  }

  private func slider(
    _ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double
  )
    -> some View
  {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11))
        .frame(width: 130, alignment: .leading)
      Slider(value: value, in: range, step: step)
    }
  }

  private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .medium))
      .foregroundColor(.white)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(Capsule().fill(Color.white.opacity(0.14)))
  }
}
