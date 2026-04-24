import SwiftUI

struct WeeklySankeyFilterTuningPreview: View {
  @State var variant: WeeklySankeyPreviewVariant = .airierOptimized
  @State var minAppSharePercent: Double = 2
  @State var capsVisibleApps = false
  @State var maxVisibleApps = 6

  var appFilterPolicy: WeeklySankeyAppFilterPolicy {
    WeeklySankeyAppFilterPolicy(
      minAppSharePercent: Int(minAppSharePercent.rounded()),
      maxVisibleApps: capsVisibleApps ? maxVisibleApps : nil
    )
  }

  var diagnostics: WeeklySankeyPreviewDiagnostics {
    WeeklySankeyDistributionSection.previewDiagnostics(
      for: variant,
      appFilterPolicy: appFilterPolicy
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Text("Layout")
            .font(.custom("Nunito-Regular", size: 12))

          Picker("Layout", selection: $variant) {
            Text("Base").tag(WeeklySankeyPreviewVariant.balanced)
            Text("Airy").tag(WeeklySankeyPreviewVariant.airier)
            Text("Optimized").tag(WeeklySankeyPreviewVariant.airierOptimized)
          }
          .pickerStyle(.segmented)
          .frame(width: 320)
        }

        HStack(spacing: 12) {
          Text("Min App Share")
            .font(.custom("Nunito-Regular", size: 12))

          Slider(value: $minAppSharePercent, in: 1...10, step: 1)
            .frame(width: 220)

          Text("\(Int(minAppSharePercent.rounded()))%")
            .font(.custom("Nunito-Regular", size: 12))
            .monospacedDigit()
        }

        HStack(spacing: 12) {
          Toggle("Cap Right Rail", isOn: $capsVisibleApps)
            .toggleStyle(.checkbox)
            .font(.custom("Nunito-Regular", size: 12))

          Stepper(value: $maxVisibleApps, in: 3...10) {
            Text("Top \(maxVisibleApps)")
              .font(.custom("Nunito-Regular", size: 12))
              .monospacedDigit()
          }
          .disabled(!capsVisibleApps)
          .opacity(capsVisibleApps ? 1 : 0.55)
        }
      }

      Text(appFilterPolicy.summary)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))

      Text(diagnostics.summary)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))

      WeeklySankeyDistributionSection(
        variant: variant,
        appFilterPolicy: appFilterPolicy
      )
    }
    .padding(18)
    .background(Color(hex: "F7F3F0"))
  }
}

struct WeeklySankeyPreviewGallery: View {
  let rows = WeeklySankeyPreviewVariant.allCases.map { variant in
    WeeklySankeyPreviewComparisonRow(
      variant: variant,
      diagnostics: WeeklySankeyDistributionSection.previewDiagnostics(for: variant)
    )
  }

  var body: some View {
    let sortedRows = rows.sorted { lhs, rhs in
      if abs(lhs.diagnostics.programmaticScore - rhs.diagnostics.programmaticScore) > 0.5 {
        return lhs.diagnostics.programmaticScore < rhs.diagnostics.programmaticScore
      }
      return lhs.variant.id < rhs.variant.id
    }

    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Programmatic Sankey Iterations")
          .font(.custom("Nunito-Bold", size: 16))
          .foregroundStyle(Color(hex: "3B2418"))

        Text(
          "Lower score is better. The score heavily penalizes label overlaps and right-rail overflow, then uses crossings as the secondary tie-breaker."
        )
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))
      }
      .padding(.horizontal, 2)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(sortedRows.enumerated()), id: \.element.variant.id) { index, row in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(index == 0 ? "Best" : "\(index + 1)")
              .font(.custom("Nunito-Bold", size: 11))
              .foregroundStyle(index == 0 ? Color.white : Color(hex: "7C5A46"))
              .padding(.horizontal, index == 0 ? 10 : 8)
              .padding(.vertical, 4)
              .background(
                Capsule(style: .continuous)
                  .fill(index == 0 ? Color(hex: "B46531") : Color.white)
              )
              .overlay(
                Capsule(style: .continuous)
                  .stroke(Color(hex: "E3D6CF"), lineWidth: 1)
              )

            Text(row.variant.title)
              .font(.custom("Nunito-Bold", size: 13))
              .foregroundStyle(Color(hex: "3B2418"))

            Text(row.diagnostics.shortSummary)
              .font(.custom("Nunito-Regular", size: 12))
              .foregroundStyle(Color(hex: "6E584B"))
          }
        }
      }

      ForEach(WeeklySankeyPreviewVariant.allCases) { variant in
        WeeklySankeyPreviewCard(variant: variant)
      }
    }
    .padding(18)
  }
}

enum WeeklySankeyPreviewVariant: String, CaseIterable, Identifiable {
  case balanced
  case airier
  case airierOptimized

  var id: String { rawValue }

  var title: String {
    switch self {
    case .balanced:
      return "Baseline"
    case .airier:
      return "Airier"
    case .airierOptimized:
      return "Airier + Optimized Order"
    }
  }

  var summary: String {
    switch self {
    case .balanced:
      return "Current art-directed geometry with the original fixed downstream order."
    case .airier:
      return "Stronger left-to-right taper, looser right rail, softer downstream curves."
    case .airierOptimized:
      return "Airier geometry plus barycenter sweeps and local swaps to reduce crossings."
    }
  }

  var fixture: WeeklySankeyFixture {
    switch self {
    case .balanced:
      return .balanced
    case .airier, .airierOptimized:
      return .airier
    }
  }

  var layoutOptions: SankeyLayoutOptions {
    switch self {
    case .balanced, .airier:
      return SankeyLayoutOptions(
        bandOrdering: .oppositeNodeCenter,
        nodeOrdering: .input,
        sweepPasses: 0,
        localSwapPasses: 0
      )
    case .airierOptimized:
      return .aesthetic
    }
  }
}

struct WeeklySankeyPreviewDiagnostics {
  let programmaticScore: CGFloat
  let weightedCrossings: CGFloat
  let labelOverlapPairs: Int
  let tightestLabelGap: CGFloat
  let appBottomClearance: CGFloat

  var shortSummary: String {
    let scoreText = String(format: "%.0f", programmaticScore)
    let crossingText = String(format: "%.0f", weightedCrossings)
    let clearanceText = String(format: "%.1f", appBottomClearance)
    return
      "Score \(scoreText) | crossings \(crossingText) | overlaps \(labelOverlapPairs) | clearance \(clearanceText)pt"
  }

  var summary: String {
    let scoreText = String(format: "%.0f", programmaticScore)
    let crossingText = String(format: "%.0f", weightedCrossings)
    let gapText = String(format: "%.1f", tightestLabelGap)
    let clearanceText = String(format: "%.1f", appBottomClearance)
    return
      "Programmatic score: \(scoreText) | Weighted crossings: \(crossingText) | Label overlaps: \(labelOverlapPairs) | Tightest label gap: \(gapText)pt | App bottom clearance: \(clearanceText)pt"
  }
}

struct WeeklySankeyPreviewComparisonRow {
  let variant: WeeklySankeyPreviewVariant
  let diagnostics: WeeklySankeyPreviewDiagnostics
}

struct WeeklySankeyPreviewCard: View {
  let variant: WeeklySankeyPreviewVariant

  var diagnostics: WeeklySankeyPreviewDiagnostics {
    WeeklySankeyDistributionSection.previewDiagnostics(for: variant)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        Text(variant.title)
          .font(.custom("Nunito-Bold", size: 12))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Capsule(style: .continuous)
              .fill(Color(hex: "B46531"))
          )

        Text(variant.summary)
          .font(.custom("Nunito-Bold", size: 13))
          .foregroundStyle(Color(hex: "3B2418"))
      }

      Text(diagnostics.summary)
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))

      WeeklySankeyDistributionSection(variant: variant)
    }
  }
}
