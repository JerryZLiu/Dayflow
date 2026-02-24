import SwiftUI

struct SettingsCard<Content: View>: View {
  let title: String
  let subtitle: String?
  let content: () -> Content

  init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.custom("Nunito", size: 18))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.85))
        if let subtitle {
          Text(subtitle)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(.black.opacity(0.45))
        }
      }
      content()
    }
    .padding(28)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(Color.white.opacity(0.72))
        .overlay(
          RoundedRectangle(cornerRadius: 18)
            .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 12)
    )
  }
}
