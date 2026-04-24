import SwiftUI

struct WeeklyTreemapCategoryCard: View {
  let category: WeeklyTreemapCategory
  let onLeafHover: (WeeklyTreemapHoverState?) -> Void

  enum Design {
    static let cornerRadius: CGFloat = 4
    static let tileGap: CGFloat = 4
    static let horizontalPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    static let headerHorizontalPadding: CGFloat = 10
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 8
    static let minimumContentHeight: CGFloat = 36
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(category.palette.shellFill)
        .overlay(
          RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            .stroke(category.palette.shellBorder, lineWidth: 1)
        )

      VStack(spacing: 0) {
        WeeklyTreemapCategoryHeader(category: category)
          .padding(.horizontal, Design.headerHorizontalPadding)
          .padding(.top, Design.headerTopPadding)
          .padding(.bottom, Design.headerBottomPadding)

        GeometryReader { proxy in
          let contentRect = CGRect(origin: .zero, size: proxy.size)
          let displayApps = WeeklyTreemapAggregation.appsForDisplay(
            category.apps,
            in: contentRect,
            gap: Design.tileGap
          )
          let placements = SquarifiedTreemapLayout.place(
            displayApps,
            value: { $0.weight },
            order: WeeklyTreemapApp.displayOrder,
            in: contentRect,
            gap: Design.tileGap
          )

          ZStack(alignment: .topLeading) {
            ForEach(placements) { placement in
              WeeklyTreemapLeafTile(
                app: placement.item,
                palette: category.palette,
                onHoverChanged: onLeafHover
              )
              .frame(width: placement.frame.width, height: placement.frame.height)
              .offset(x: placement.frame.minX, y: placement.frame.minY)
            }
          }
        }
        .padding(.horizontal, Design.horizontalPadding)
        .padding(.bottom, Design.bottomPadding)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
  }
}

struct WeeklyTreemapCategoryHeader: View {
  let category: WeeklyTreemapCategory

  var body: some View {
    ViewThatFits {
      HStack(spacing: 8) {
        titleText
        Spacer(minLength: 8)
        durationText
      }

      VStack(alignment: .leading, spacing: 0) {
        titleText
        durationText
      }

      titleText
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  var titleText: some View {
    Text(category.name)
      .font(.custom("Nunito-Regular", size: 12))
      .foregroundStyle(category.palette.headerText)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }

  var durationText: some View {
    Text(category.formattedDuration)
      .font(.custom("Nunito-Regular", size: 12))
      .foregroundStyle(category.palette.headerText)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }
}

struct WeeklyTreemapLeafTile: View {
  let app: WeeklyTreemapApp
  let palette: WeeklyTreemapPalette
  let onHoverChanged: (WeeklyTreemapHoverState?) -> Void

  enum Design {
    static let cornerRadius: CGFloat = 4
  }

  var body: some View {
    GeometryReader { proxy in
      let typography = WeeklyTreemapLeafTypography.resolve(for: proxy.size)
      let presentationMode = WeeklyTreemapLeafPresentationMode.resolve(
        for: proxy.size,
        hasChange: app.change != nil
      )

      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(palette.tileFill)
        .overlay(
          RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            .stroke(palette.tileBorder, lineWidth: 1)
        )
        .overlay {
          if app.isPlaceholder {
            EmptyView()
          } else {
            tileContent(using: typography, presentationMode: presentationMode)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding(typography.padding)
          }
        }
        .overlay {
          EmptyView()
        }
        .contentShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
        .onHover { isHovering in
          guard presentationMode != .full, !app.isPlaceholder else {
            if !isHovering {
              onHoverChanged(nil)
            }
            return
          }

          if isHovering {
            onHoverChanged(
              WeeklyTreemapHoverState(
                app: app,
                palette: palette,
                frame: proxy.frame(in: .named(weeklyTreemapContentCoordinateSpace))
              )
            )
          } else {
            onHoverChanged(nil)
          }
        }
    }
  }

  func fullContent(using typography: WeeklyTreemapLeafTypography) -> some View {
    VStack(spacing: typography.lineSpacing) {
      nameText(fontSize: typography.nameFontSize)

      Text(app.formattedDuration)
        .font(.custom("Nunito-Regular", size: typography.detailFontSize))
        .foregroundStyle(Color(hex: "333333"))
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      if let change = app.change {
        Text(change.text)
          .font(.custom("SpaceMono-Regular", size: typography.deltaFontSize))
          .foregroundStyle(change.color)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
    }
  }

  func compactContent(using typography: WeeklyTreemapLeafTypography) -> some View {
    VStack(spacing: max(typography.lineSpacing - 1, 1)) {
      nameText(fontSize: max(typography.nameFontSize - 2, 11))

      Text(app.formattedDuration)
        .font(.custom("Nunito-Regular", size: max(typography.detailFontSize - 1, 10)))
        .foregroundStyle(Color(hex: "333333"))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
  }

  func labelOnlyContent(using typography: WeeklyTreemapLeafTypography) -> some View {
    nameText(fontSize: max(typography.nameFontSize - 3, 10))
  }

  @ViewBuilder
  func tileContent(
    using typography: WeeklyTreemapLeafTypography,
    presentationMode: WeeklyTreemapLeafPresentationMode
  ) -> some View {
    switch presentationMode {
    case .full:
      fullContent(using: typography)
    case .compact:
      compactContent(using: typography)
    case .labelOnly:
      labelOnlyContent(using: typography)
    }
  }

  func nameText(fontSize: CGFloat) -> some View {
    Text(app.name)
      .font(.custom("InstrumentSerif-Regular", size: fontSize))
      .foregroundStyle(Color.black)
      .multilineTextAlignment(.center)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}

struct WeeklyTreemapHoverCard: View {
  let app: WeeklyTreemapApp
  let palette: WeeklyTreemapPalette

  enum Design {
    static let cornerRadius: CGFloat = 6
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(app.name)
        .font(.custom("InstrumentSerif-Regular", size: 17))
        .foregroundStyle(Color.black)
        .lineLimit(1)

      Text(app.formattedDuration)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "333333"))
        .lineLimit(1)

      if let change = app.change {
        Text(change.text)
          .font(.custom("SpaceMono-Regular", size: 12))
          .foregroundStyle(change.color)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .fill(Color.white.opacity(0.96))
        .overlay(
          RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
            .fill(palette.shellFill.opacity(0.85))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .stroke(palette.shellBorder.opacity(0.95), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 6)
  }
}

struct WeeklyTreemapHoverState {
  let app: WeeklyTreemapApp
  let palette: WeeklyTreemapPalette
  let frame: CGRect
}

enum WeeklyTreemapLeafTypography {
  case large
  case medium
  case compact

  var nameFontSize: CGFloat {
    switch self {
    case .large:
      return 20
    case .medium:
      return 16
    case .compact:
      return 13
    }
  }

  var detailFontSize: CGFloat {
    switch self {
    case .large, .medium:
      return 12
    case .compact:
      return 10
    }
  }

  var deltaFontSize: CGFloat {
    switch self {
    case .large, .medium:
      return 12
    case .compact:
      return 10
    }
  }

  var lineSpacing: CGFloat {
    switch self {
    case .large:
      return 4
    case .medium:
      return 3
    case .compact:
      return 2
    }
  }

  var padding: CGFloat {
    switch self {
    case .large:
      return 12
    case .medium:
      return 10
    case .compact:
      return 6
    }
  }

  static func resolve(for size: CGSize) -> WeeklyTreemapLeafTypography {
    if size.width >= 160, size.height >= 110 {
      return .large
    }

    if size.width >= 90, size.height >= 54 {
      return .medium
    }

    return .compact
  }
}

enum WeeklyTreemapLeafPresentationMode {
  case full
  case compact
  case labelOnly

  static func resolve(for size: CGSize, hasChange: Bool) -> WeeklyTreemapLeafPresentationMode {
    let fullHeight: CGFloat = hasChange ? 72 : 56
    if size.width >= 90, size.height >= fullHeight {
      return .full
    }

    if size.width >= 58, size.height >= 34 {
      return .compact
    }

    return .labelOnly
  }
}
