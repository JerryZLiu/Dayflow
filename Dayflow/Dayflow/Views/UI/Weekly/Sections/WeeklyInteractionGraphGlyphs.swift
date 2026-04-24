import SwiftUI

struct WeeklyInteractionGraphNodeBadge: View {
  let node: WeeklyInteractionGraphNodeLayout

  var shellGradient: LinearGradient {
    switch node.category {
    case .work:
      return LinearGradient(
        colors: [Color(hex: "EEF3FF"), Color(hex: "F8FAFF")],
        startPoint: .top,
        endPoint: .bottom
      )
    case .personal:
      return LinearGradient(
        colors: [Color(hex: "EFECE8"), Color(hex: "F8F6F4")],
        startPoint: .top,
        endPoint: .bottom
      )
    case .distraction:
      return LinearGradient(
        colors: [Color(hex: "FFDCCF"), Color(hex: "F8F2EE")],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(shellGradient)
        .overlay(
          Circle()
            .stroke(node.category.borderColor, lineWidth: node.borderWidth)
        )
        .shadow(
          color: node.category.borderColor.opacity(node.isCenter ? 0.22 : 0.08),
          radius: node.isCenter ? 5 : 2,
          x: 0,
          y: 0
        )

      WeeklyInteractionGraphGlyphView(
        glyph: node.glyph,
        diameter: node.diameter
      )
      .padding(node.diameter * 0.2)
    }
  }
}

struct WeeklyInteractionGraphGlyphView: View {
  let glyph: WeeklyInteractionGraphGlyph
  let diameter: CGFloat

  var body: some View {
    Group {
      switch glyph {
      case .figma:
        WeeklyInteractionFigmaGlyph()
      case .youtube:
        WeeklyInteractionYouTubeGlyph()
      case .x:
        WeeklyInteractionMonogramGlyph(
          text: "X",
          background: .black,
          foreground: .white,
          cornerRadius: diameter * 0.11,
          fontSize: diameter * 0.34
        )
      case .notion:
        WeeklyInteractionNotionGlyph(fontSize: diameter * 0.34)
      case .slack:
        WeeklyInteractionSlackGlyph()
      case .zoom:
        WeeklyInteractionZoomGlyph(fontSize: diameter * 0.24)
      case .reddit:
        WeeklyInteractionMonogramGlyph(
          text: "r",
          background: Color(hex: "FC7645"),
          foreground: .white,
          cornerRadius: diameter * 0.5,
          fontSize: diameter * 0.34
        )
      case .linear:
        WeeklyInteractionMonogramGlyph(
          text: "L",
          background: Color(hex: "2B2724"),
          foreground: .white,
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      case .framer:
        WeeklyInteractionMonogramGlyph(
          text: "F",
          background: .black,
          foreground: .white,
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      case .bookmark:
        WeeklyInteractionBookmarkGlyph()
      case .cube:
        WeeklyInteractionCubeGlyph()
      case .burst:
        WeeklyInteractionBurstGlyph()
      case .bullseye:
        WeeklyInteractionBullseyeGlyph()
      case .bars:
        WeeklyInteractionBarsGlyph()
      case .asset(let name):
        Image(name)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      case .monogram(let text, let backgroundHex, let foregroundHex):
        WeeklyInteractionMonogramGlyph(
          text: text,
          background: Color(hex: backgroundHex),
          foreground: Color(hex: foregroundHex),
          cornerRadius: diameter * 0.12,
          fontSize: diameter * 0.34
        )
      }
    }
  }
}

struct WeeklyInteractionMonogramGlyph: View {
  let text: String
  let background: Color
  let foreground: Color
  let cornerRadius: CGFloat
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(background)
      .overlay {
        Text(text)
          .font(.system(size: fontSize, weight: .semibold, design: .rounded))
          .foregroundStyle(foreground)
      }
  }
}

struct WeeklyInteractionFigmaGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let circle = width * 0.28
      let pillWidth = width * 0.56

      ZStack {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: circle * 0.7, style: .continuous)
              .fill(Color(hex: "F96E4F"))
              .frame(width: pillWidth, height: circle)

            Circle()
              .fill(Color(hex: "29B6F6"))
              .frame(width: circle, height: circle)
          }

          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: circle * 0.7, style: .continuous)
              .fill(Color(hex: "A857E8"))
              .frame(width: pillWidth, height: circle)

            Circle()
              .fill(Color(hex: "29B6F6"))
              .frame(width: circle, height: circle)
          }

          HStack(spacing: 0) {
            Circle()
              .fill(Color(hex: "34C759"))
              .frame(width: circle, height: circle)

            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

struct WeeklyInteractionYouTubeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let height = proxy.size.height

      RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        .fill(Color(hex: "FF2626"))
        .overlay {
          Image(systemName: "play.fill")
            .font(.system(size: width * 0.28, weight: .bold))
            .foregroundStyle(.white)
            .offset(x: width * 0.03)
        }
    }
    .aspectRatio(1.35, contentMode: .fit)
  }
}

struct WeeklyInteractionSlackGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let bar = width * 0.18
      let long = width * 0.44

      ZStack {
        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "36C5F0"))
          .frame(width: bar, height: long)
          .offset(x: -bar * 0.9, y: long * 0.2)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "2EB67D"))
          .frame(width: long, height: bar)
          .offset(x: -bar * 0.2, y: bar * 0.9)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "E01E5A"))
          .frame(width: bar, height: long)
          .offset(x: bar * 0.9, y: -long * 0.2)

        RoundedRectangle(cornerRadius: bar * 0.65, style: .continuous)
          .fill(Color(hex: "ECB22E"))
          .frame(width: long, height: bar)
          .offset(x: bar * 0.2, y: -bar * 0.9)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

struct WeeklyInteractionNotionGlyph: View {
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(.white)
      .overlay(
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .stroke(.black, lineWidth: 1.5)
      )
      .overlay {
        Text("N")
          .font(.system(size: fontSize, weight: .black, design: .serif))
          .foregroundStyle(.black)
      }
  }
}

struct WeeklyInteractionZoomGlyph: View {
  let fontSize: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
      .fill(Color(hex: "4C8BFF"))
      .overlay {
        Image(systemName: "video.fill")
          .font(.system(size: fontSize, weight: .semibold))
          .foregroundStyle(.white)
      }
  }
}

struct WeeklyInteractionBookmarkGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width

      Image(systemName: "bookmark.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(Color(hex: "FC7645"))
        .frame(width: width * 0.56, height: width * 0.68)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionCubeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        Image(systemName: "shippingbox.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(Color(hex: "2B2724"))
          .frame(width: size * 0.78, height: size * 0.78)

        Image(systemName: "shippingbox")
          .resizable()
          .scaledToFit()
          .foregroundStyle(Color(hex: "A2A2A2"))
          .frame(width: size * 0.78, height: size * 0.78)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionBurstGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)
      let strokeLength = size * 0.34
      let strokeWidth = max(size * 0.028, 1.2)

      ZStack {
        ForEach(0..<12, id: \.self) { index in
          Capsule(style: .continuous)
            .fill(Color(hex: "E08A69"))
            .frame(width: strokeWidth, height: strokeLength)
            .offset(y: -size * 0.18)
            .rotationEffect(.degrees(Double(index) * 30))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionBullseyeGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)

      ZStack {
        Circle()
          .stroke(Color(hex: "B5C34C"), lineWidth: max(size * 0.1, 2))
          .frame(width: size * 0.66, height: size * 0.66)

        Circle()
          .stroke(Color(hex: "69751E"), lineWidth: max(size * 0.08, 1.5))
          .frame(width: size * 0.38, height: size * 0.38)

        Circle()
          .fill(Color(hex: "69751E"))
          .frame(width: size * 0.12, height: size * 0.12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionBarsGlyph: View {
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let barWidth = width * 0.12

      HStack(alignment: .bottom, spacing: width * 0.06) {
        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(Color(hex: "7E7E85"))
          .frame(width: barWidth, height: width * 0.34)

        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(Color(hex: "606067"))
          .frame(width: barWidth, height: width * 0.54)

        RoundedRectangle(cornerRadius: barWidth, style: .continuous)
          .fill(Color(hex: "7E7E85"))
          .frame(width: barWidth, height: width * 0.24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct WeeklyInteractionGraphLegend: View {
  var body: some View {
    HStack(spacing: 24) {
      legendItem(for: .work, title: "Work")
      legendItem(for: .personal, title: "Personal")
      legendItem(for: .distraction, title: "Distraction")
    }
  }

  func legendItem(
    for category: WeeklyInteractionGraphCategory,
    title: String
  ) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(category.fillColor)
        .overlay(
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(category.borderColor, lineWidth: 1.75)
        )
        .frame(width: 16, height: 12)

      Text(title)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(.black)
    }
  }
}
