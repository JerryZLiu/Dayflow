import SwiftUI

struct WeeklySankeyPlainLabel: View {
  let content: WeeklySankeyNodeContent

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(content.title)
        .font(.custom("Nunito-Bold", size: 14))
        .foregroundStyle(.black)
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      WeeklySankeyMetadataLine(
        durationText: content.durationText,
        shareText: content.shareText
      )
    }
  }
}

struct WeeklySankeyAppLabel: View {
  let content: WeeklySankeyNodeContent
  let iconSource: WeeklySankeyIconSource

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      WeeklySankeyIconView(source: iconSource)
        .frame(width: 18, height: 18)
        .padding(.top, 1.5)

      VStack(alignment: .leading, spacing: 3) {
        Text(content.title)
          .font(.custom("Nunito-Bold", size: 14))
          .foregroundStyle(.black)
          .lineLimit(1)
          .minimumScaleFactor(0.85)

        WeeklySankeyMetadataLine(
          durationText: content.durationText,
          shareText: content.shareText
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct WeeklySankeyMetadataLine: View {
  let durationText: String
  let shareText: String

  var body: some View {
    Text("\(durationText) | \(shareText)")
      .font(.custom("Nunito-Regular", size: 11))
      .foregroundStyle(Color(hex: "717171"))
      .lineLimit(1)
      .minimumScaleFactor(0.85)
  }
}

struct WeeklySankeyIconView: View {
  let source: WeeklySankeyIconSource

  @State var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        fallbackView
      }
    }
    .frame(width: 18, height: 18)
    .task(id: source.cacheKey) {
      image = await source.resolveImage()
    }
  }

  @ViewBuilder
  var fallbackView: some View {
    switch source {
    case .monogram(let text, let background, let foreground):
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(background)
        .overlay {
          Text(text)
            .font(.custom("Nunito-Bold", size: 9))
            .foregroundStyle(foreground)
        }
    case .none:
      Color.clear
    default:
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(Color.black.opacity(0.05))
    }
  }
}

enum WeeklySankeyIconSource {
  case asset(String)
  case favicon(raw: String, host: String)
  case monogram(text: String, background: Color, foreground: Color)
  case none

  var cacheKey: String {
    switch self {
    case .asset(let name):
      return "asset:\(name)"
    case .favicon(let raw, let host):
      return "favicon:\(raw):\(host)"
    case .monogram(let text, _, _):
      return "monogram:\(text)"
    case .none:
      return "none"
    }
  }

  func resolveImage() async -> NSImage? {
    switch self {
    case .asset(let name):
      return NSImage(named: name)
    case .favicon(let raw, let host):
      return await FaviconService.shared.fetchFavicon(
        primaryRaw: raw,
        secondaryRaw: nil,
        primaryHost: host,
        secondaryHost: nil
      )
    case .monogram, .none:
      return nil
    }
  }
}

enum WeeklySankeyLabelKind {
  case plain
  case app(WeeklySankeyIconSource)
}

struct WeeklySankeyNodeContent: Identifiable {
  let id: String
  let title: String
  let durationText: String
  let shareText: String
  let barColorHex: String
  let labelKind: WeeklySankeyLabelKind

  var barColor: Color {
    Color(hex: barColorHex)
  }

  var labelSize: CGSize {
    switch labelKind {
    case .plain:
      return CGSize(width: 152, height: 34)
    case .app:
      return CGSize(width: 136, height: 34)
    }
  }

  var labelAnchorY: CGFloat {
    switch labelKind {
    case .plain:
      return labelSize.height / 2
    case .app:
      // App labels read off the icon first, so align the icon center to the bar.
      return 10.5
    }
  }
}

struct WeeklySankeyLabelPlacement {
  let origin: CGPoint
}

struct WeeklySankeyLabelCandidate {
  let id: String
  let columnID: String
  let preferredTopY: CGFloat
  let originX: CGFloat
  let size: CGSize
}
