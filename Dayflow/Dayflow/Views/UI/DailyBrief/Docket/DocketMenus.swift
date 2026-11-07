//
//  DocketMenus.swift
//  Dayflow
//
//  The gear menu (which agent, and whether to paste or run the prompt) and the folder
//  menu (where the agent works). The page draws them above everything, at the position
//  of the button that opened them, with a click-catcher behind that closes them.
//

import AppKit
import SwiftUI

/// Attach with `.overlayPreferenceValue(DocketAnchorKey.self)` on the page.
struct DocketMenuLayer: View {
  let anchors: [String: Anchor<CGRect>]

  @ObservedObject private var ui = DocketUIState.shared

  var body: some View {
    GeometryReader { proxy in
      if let menu = ui.openMenu {
        ZStack(alignment: .topLeading) {
          Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture { ui.openMenu = nil }

          switch menu {
          case .gear:
            if let anchor = anchors["gear"] {
              let rect = proxy[anchor]
              DocketGearMenu()
                .alignmentGuide(.leading) { $0[.trailing] - rect.maxX }
                .alignmentGuide(.top) { $0[.bottom] - (rect.minY - 6.5) }
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
          case .folder(let title):
            if let anchor = anchors["folder:\(title)"] {
              let rect = proxy[anchor]
              DocketFolderMenu(title: title)
                .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - rect.midX }
                .alignmentGuide(.top) { _ in -(rect.maxY + 6) }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
          }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      }
    }
    .animation(.easeOut(duration: 0.16), value: ui.openMenu)
  }
}

// MARK: - Gear menu

private struct DocketGearMenu: View {
  @ObservedObject private var store = DailyBriefStore.shared
  @AppStorage(DocketTransitionStyle.defaultsKey) private var transition = DocketTransitionStyle
    .catchOnTop.rawValue
  @AppStorage(DocketPetKind.defaultsKey) private var pet = DocketPetKind.clawd.rawValue

  var body: some View {
    VStack(spacing: 0) {
      section("Providers", corners: .top) {
        ForEach(DailyBriefAgent.allCases, id: \.self) { agent in
          option(isOn: store.docketAgent == agent) {
            store.docketAgent = agent
          } label: {
            HStack(spacing: 6) {
              Image(agent.iconAsset)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
              Text(agent.displayName)
            }
          } note: {
            EmptyView()
          }
        }
      }
      section("Hand-off method", corners: store.docketHandoffMethod == .paste ? .middle : .bottom) {
        option(isOn: store.docketHandoffMethod == .paste) {
          store.docketHandoffMethod = .paste
        } label: {
          Text("Paste the prompt")
        } note: {
          note(
            "Dayflow will open the app to your selected provider and paste the prompt to the corresponding project."
          )
        }
        option(isOn: store.docketHandoffMethod == .run) {
          store.docketHandoffMethod = .run
        } label: {
          Text("Run the prompt")
        } note: {
          note(
            "Dayflow will automatically run the prompt in the app of your selected provider.")
        }
      }
      // For trying the paste transitions side by side.
      if store.docketHandoffMethod == .paste {
        let showsPets = transition == DocketTransitionStyle.catchOnTop.rawValue
        section("Transition (testing)", corners: showsPets ? .middle : .bottom) {
          ForEach(DocketTransitionStyle.allCases, id: \.self) { style in
            option(isOn: transition == style.rawValue) {
              transition = style.rawValue
            } label: {
              Text(style.displayName)
            } note: {
              note(style.note)
            }
          }
        }
        if showsPets {
          section("Pet (testing)", corners: .bottom) {
            ForEach(DocketPetKind.allCases, id: \.self) { kind in
              option(isOn: pet == kind.rawValue) {
                pet = kind.rawValue
              } label: {
                Text(kind.displayName)
              } note: {
                EmptyView()
              }
            }
          }
        }
      }
    }
    .frame(width: 275)
    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 4)
  }

  private enum Corners { case top, middle, bottom }

  private func section<Content: View>(
    _ title: String, corners: Corners, @ViewBuilder content: () -> Content
  )
    -> some View
  {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: corners == .top ? 12 : 0, bottomLeadingRadius: corners == .bottom ? 12 : 0,
      bottomTrailingRadius: corners == .bottom ? 12 : 0,
      topTrailingRadius: corners == .top ? 12 : 0,
      style: .continuous)
    return VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(DailyBriefFonts.sans(12, weight: .semibold))
        .foregroundStyle(Color(hex: "B1B1B1"))
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(shape.fill(.ultraThinMaterial))
    .background(shape.fill(Color(red: 1, green: 254 / 255, blue: 254 / 255).opacity(0.85)))
    .overlay(shape.strokeBorder(Color(hex: "F0E5E1"), lineWidth: 1))
    .padding(.top, corners == .top ? 0 : -1)
  }

  private func option<Label: View, Note: View>(
    isOn: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label,
    @ViewBuilder note: () -> Note
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 6) {
        Image(isOn ? "DocketRadioOn" : "DocketRadioOff")
          .resizable()
          .frame(width: 16, height: 16)
        VStack(alignment: .leading, spacing: 4) {
          label()
            .font(DailyBriefFonts.sans(14, weight: .medium))
            .foregroundStyle(DocketColors.ink)
          note()
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(DailyBriefFonts.sans(12))
      .foregroundStyle(DocketColors.promptOpen)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Folder menu

private struct DocketFolderMenu: View {
  let title: String

  @ObservedObject private var store = DailyBriefStore.shared
  @ObservedObject private var ui = DocketUIState.shared

  var body: some View {
    let current = store.docketFolder(for: title)
    VStack(alignment: .leading, spacing: 8) {
      row("No folder", isChecked: current == nil) { pick(nil) }

      divider

      Text("RECENT")
        .font(DailyBriefFonts.sans(12, weight: .bold))
        .foregroundStyle(DocketColors.labelOpen)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(store.recentFolders, id: \.self) { path in
          row(URL(fileURLWithPath: path).lastPathComponent, isChecked: current == path) {
            pick(path)
          }
          .help(path)
        }
      }

      divider

      row("Open folder…", isChecked: false, action: openFolder)
    }
    .padding(.vertical, 12)
    .padding(.leading, 13)
    .padding(.trailing, 12)
    .frame(width: 200.29, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: "FFFDFC")))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
        Color(hex: "EFE4E1"), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.1), radius: 3, y: 2)
  }

  private var divider: some View {
    Rectangle().fill(DocketColors.divider).frame(height: 1)
  }

  private func row(_ label: String, isChecked: Bool, action: @escaping () -> Void) -> some View {
    DocketFolderRow(label: label, isChecked: isChecked, action: action)
  }

  private func pick(_ path: String?) {
    store.setDocketFolder(path, for: title)
    ui.openMenu = nil
  }

  private func openFolder() {
    ui.openMenu = nil
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Use folder"
    panel.message = "Pick the folder the agent should work in."
    if panel.runModal() == .OK, let url = panel.url {
      store.setDocketFolder(url.path, for: title)
    }
  }
}

private struct DocketFolderRow: View {
  let label: String
  let isChecked: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(label)
          .font(DailyBriefFonts.sans(14))
          .foregroundStyle(isHovered ? DocketColors.folder : DocketColors.title)
          .lineLimit(1)
        Spacer(minLength: 0)
        if isChecked {
          Image("DocketMenuCheck")
            .resizable()
            .frame(width: 16, height: 16)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .pointingHandCursor()
  }
}

// MARK: - Dismiss reason pop-up

/// "Help us improve the product": asks why a task was dismissed. Sits in the page's
/// bottom right corner.
struct DocketAskPopup: View {
  let title: String

  @ObservedObject private var store = DailyBriefStore.shared
  @ObservedObject private var ui = DocketUIState.shared
  @State private var reason: String?
  @State private var shake: CGFloat = 0
  @State private var isSubmitted = false
  @State private var isSubmitHovered = false

  static let reasons = [
    "That task was irrelevant to what I’m working on",
    "That task should not be handed to an agent",
    "The task did not capture what I was actually supposed to do",
    "The prompt provided was not helpful",
    "Other",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("HELP US IMPROVE THE PRODUCT")
        .font(DailyBriefFonts.sans(12, weight: .medium))
        .foregroundStyle(Color(hex: "AB8C82"))
        .padding(.bottom, 10)

      (Text("You dismissed ").foregroundColor(Color(hex: "8A8A8A"))
        + Text(title).fontWeight(.medium).foregroundColor(DocketColors.ink))
        .font(DailyBriefFonts.sans(13))
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 16)
        .padding(.bottom, 12)

      Text("Tell us why:")
        .font(DailyBriefFonts.sans(14, weight: .medium))
        .foregroundStyle(DocketColors.ink)
        .padding(.bottom, 10)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(Self.reasons, id: \.self) { option in
          Button {
            reason = option
          } label: {
            HStack(alignment: .top, spacing: 6) {
              Image(reason == option ? "DocketRadioOn" : "DocketRadioOff")
                .resizable()
                .frame(width: 16, height: 16)
              Text(option)
                .font(DailyBriefFonts.sans(13))
                .foregroundStyle(Color(hex: "4E4E4E"))
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }

      HStack {
        Spacer()
        Button(action: submit) {
          Text("Submit")
            .font(DailyBriefFonts.sans(13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 36)
            .background(Capsule().fill(Color(hex: "FF9F6F")))
            .overlay(
              InnerGlow(
                shape: Capsule(),
                color: Color(red: 1, green: 220 / 255, blue: 203 / 255).opacity(0.9), radius: 1.5)
            )
            .overlay(Capsule().strokeBorder(Color(hex: "F4C8B1"), lineWidth: 0.5))
            .shadow(
              color: isSubmitHovered
                ? Color(red: 1, green: 120 / 255, blue: 60 / 255).opacity(0.18)
                : Color.black.opacity(0.06),
              radius: isSubmitHovered ? 5 : 2, y: isSubmitHovered ? 4 : 2
            )
            .scaleEffect(isSubmitHovered ? 1.02 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isSubmitHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isSubmitHovered)
        .pointingHandCursor()
      }
      .padding(.top, 16)
    }
    .padding(.top, 18)
    .padding(.horizontal, 20)
    .padding(.bottom, 16)
    .frame(width: 340)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(
          LinearGradient(
            colors: [.white, Color(hex: "FFF8F5")], startPoint: .top, endPoint: .bottom))
    )
    .overlay {
      if isSubmitted {
        submittedVeil.transition(.opacity)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
        Color(hex: "F0E5E1"), lineWidth: 1)
    )
    .overlay(alignment: .topTrailing) {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DocketColors.count)
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(12)
      .pointingHandCursor()
    }
    .shadow(
      color: Color(red: 77 / 255, green: 45 / 255, blue: 32 / 255).opacity(0.14), radius: 15, y: 10
    )
    .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
    .modifier(DocketShake(amount: shake))
  }

  private var submittedVeil: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(
          LinearGradient(
            stops: [
              .init(
                color: Color(red: 1, green: 241 / 255, blue: 232 / 255).opacity(0.61), location: 0),
              .init(
                color: Color(red: 234 / 255, green: 197 / 255, blue: 188 / 255).opacity(0.61),
                location: 0.5048),
              .init(
                color: Color(red: 174 / 255, green: 190 / 255, blue: 230 / 255).opacity(0.61),
                location: 1),
            ], startPoint: .top, endPoint: .bottom))
      Text("SUBMITTED")
        .font(DailyBriefFonts.sans(18, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: Color(hex: "C4B5AD"), radius: 4, y: 2)
    }
  }

  private func submit() {
    guard let reason else {
      withAnimation(.easeInOut(duration: 0.42)) { shake += 1 }
      return
    }
    store.setDocketDismissReason(reason, for: title)
    withAnimation(.easeOut(duration: 0.2)) { isSubmitted = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { close() }
  }

  private func close() {
    guard ui.askTitle == title else { return }
    withAnimation(DocketMotion.ease(0.3)) { ui.askTitle = nil }
  }
}

/// Shakes sideways (0, −8, 8, −8, 8, 0) each time `amount` goes up by one.
private struct DocketShake: GeometryEffect {
  var amount: CGFloat

  var animatableData: CGFloat {
    get { amount }
    set { amount = newValue }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4) * -1, y: 0))
  }
}
