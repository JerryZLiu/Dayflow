//
//  SettingsBrowserPrivacySection.swift
//  Dayflow
//
//  Hiding private browsing windows and whole categories of site. These need
//  Accessibility, so when it isn't granted the controls are visibly off and
//  the explanation and the Grant button sit right here — nobody should have
//  to go hunting for the permission somewhere else.
//

import SwiftUI

struct SettingsBrowserPrivacySection: View {
  @ObservedObject var viewModel: RecordingPrivacySettingsViewModel
  @ObservedObject var permissions: SystemPermissionsMonitor

  private var isLive: Bool { permissions.accessibilityGranted }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if !isLive {
        permissionGate
      }

      controls
        .disabled(!isLive)
        .opacity(isLive ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: isLive)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("In your browser")
        .font(.custom("Figtree", size: 13))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)
      Text(
        "Dayflow checks the front browser window on your Mac and never sends the address anywhere. It stores whether a window was private and which category matched — never the address itself."
      )
      .font(.custom("Figtree", size: 12))
      .foregroundColor(SettingsStyle.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The same card and the same helper-panel flow onboarding uses, placed
  /// inline so the grant happens where the user hit the wall.
  private var permissionGate: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "These need Accessibility, which lets Dayflow read the front window's title and address. Turn it on and the controls below go live right away — no restart."
      )
      .font(.custom("Figtree", size: 12))
      .foregroundColor(SettingsStyle.secondary)
      .fixedSize(horizontal: false, vertical: true)

      SystemPermissionRow(
        title: SystemPermission.accessibility.title,
        detail: "Needed to tell a private window apart from an ordinary one.",
        isGranted: permissions.accessibilityGranted,
        onGrant: permissions.grantAccessibility
      )
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(
        label: String(localized: "Hide private browsing windows"),
        subtitle: String(
          localized:
            "Chrome incognito, Safari private windows and Firefox private browsing get a redaction card instead of a screenshot."
        )
      ) {
        SettingsToggle(isOn: $viewModel.hidePrivateWindows)
      }

      categoryRow
      customDomainRow
      unknownWindowRow
    }
  }

  private var categoryRow: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Hide sites by category")
          .font(.custom("Figtree", size: 14))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)
        Text("Matched against a list of domains bundled with Dayflow.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }

      FlowingChips(items: SiteCategory.allCases) { category in
        SettingsToggleChip(
          title: category.title,
          help: category.detail,
          isOn: viewModel.isCategoryBlocked(category)
        ) {
          viewModel.toggleCategory(category)
        }
      }
    }
    .padding(.vertical, SettingsStyle.rowVerticalPadding)
    .overlay(alignment: .bottom) {
      Rectangle().fill(SettingsStyle.divider).frame(height: 1)
    }
  }

  private var customDomainRow: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Also hide these sites")
          .font(.custom("Figtree", size: 14))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)
        Text("Your own domains, hidden whenever any category above is on.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }

      HStack(spacing: 8) {
        TextField("example.com", text: $viewModel.customDomainDraft)
          .textFieldStyle(.plain)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(SettingsStyle.text)
          .onSubmit { viewModel.addCustomDomain() }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(SettingsStyle.editorFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(SettingsStyle.editorBorder, lineWidth: 1)
          )
          .frame(maxWidth: 240)

        SettingsSecondaryButton(
          title: String(localized: "Add"),
          isDisabled: !viewModel.canAddCustomDomain,
          action: viewModel.addCustomDomain
        )

        Spacer(minLength: 0)
      }

      if !viewModel.customDomains.isEmpty {
        FlowingChips(items: viewModel.customDomains) { domain in
          SettingsRemovableChip(title: domain) {
            viewModel.removeCustomDomain(domain)
          }
        }
      }
    }
    .padding(.vertical, SettingsStyle.rowVerticalPadding)
    .overlay(alignment: .bottom) {
      Rectangle().fill(SettingsStyle.divider).frame(height: 1)
    }
  }

  private var unknownWindowRow: some View {
    SettingsRow(
      label: String(localized: "If Dayflow can't tell"),
      subtitle: String(
        localized:
          "Browsers rename these labels per language and between versions, so a window sometimes can't be classified."
      ),
      showsDivider: false
    ) {
      Picker("", selection: $viewModel.unknownWindowHandling) {
        ForEach(UnknownBrowserWindowHandling.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 190)
    }
  }
}

/// Wraps chips onto as many lines as they need. `LazyVGrid` with an adaptive
/// column would pad every chip to the same width, which reads as a table.
private struct FlowingChips<Item: Hashable, Content: View>: View {
  let items: [Item]
  @ViewBuilder let content: (Item) -> Content

  var body: some View {
    FlowLayout(spacing: 8, lineSpacing: 8) {
      ForEach(items, id: \.self) { item in
        content(item)
      }
    }
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat
  var lineSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widest: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maxWidth {
        y += lineHeight + lineSpacing
        x = 0
        lineHeight = 0
      }
      x += size.width + spacing
      widest = max(widest, x - spacing)
      lineHeight = max(lineHeight, size.height)
    }
    return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var lineHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += lineHeight + lineSpacing
        x = bounds.minX
        lineHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}

private struct SettingsToggleChip: View {
  let title: String
  let help: String
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 11, weight: .semibold))
        Text(title)
          .font(.custom("Figtree", size: 12))
          .fontWeight(.semibold)
      }
      .foregroundColor(isOn ? SettingsStyle.ink : SettingsStyle.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(isOn ? SettingsStyle.ink.opacity(0.1) : SettingsStyle.subtleFill)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .help(help)
  }
}

private struct SettingsRemovableChip: View {
  let title: String
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.custom("Figtree", size: 12))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundColor(SettingsStyle.secondary)
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(SettingsStyle.subtleFill)
    )
  }
}
