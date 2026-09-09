import SwiftUI

// Figma: 20pt circle, 0.75pt border, soft inner glow, 12pt pencil.
struct CategoryEditCircleButton: View {
  @Environment(\.dayflowTheme) private var theme

  let action: () -> Void
  var diameter: CGFloat = 20
  var iconSize: CGFloat? = nil
  var accessibilityLabel: String = "Edit categories"

  var body: some View {
    let resolvedIconSize = iconSize ?? diameter * 0.6

    Button(action: action) {
      Image("CategoryEditButton")
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .foregroundColor(theme.isDark ? theme.controlText : .white)
        .frame(width: resolvedIconSize, height: resolvedIconSize)
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(theme.editButtonFill))
        .overlay(InnerGlow(shape: Circle(), color: theme.editButtonInnerGlow, radius: 3))
        .overlay(Circle().strokeBorder(theme.editButtonBorder, lineWidth: 0.75))
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(accessibilityLabel)
  }
}
