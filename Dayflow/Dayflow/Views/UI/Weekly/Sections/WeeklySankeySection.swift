import AppKit
import SwiftUI

struct WeeklySankeySection: View {
  @State private var dataset = WeeklySankeyDataset.timeline
  @State private var randomSeed: Int?

  private let snapshot: WeeklySankeySnapshot?
  private let showsControls: Bool
  private let width: CGFloat

  init(
    snapshot: WeeklySankeySnapshot? = nil,
    showsControls: Bool = true,
    width: CGFloat = WeeklySankeyDesign.cardWidth
  ) {
    self.snapshot = snapshot
    self.showsControls = showsControls
    self.width = width
  }

  private var model: WeeklySankeyModel {
    if let snapshot {
      return WeeklySankeyModelFactory.snapshot(snapshot)
    }

    switch dataset {
    case .timeline:
      return WeeklySankeyModelFactory.timeline()
    case .figma:
      return WeeklySankeyModelFactory.figmaBaseline()
    case .random:
      return WeeklySankeyModelFactory.random(seed: randomSeed ?? 2417)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsControls {
        controls
      }
      WeeklySankeyCard(model: model, width: width)
    }
    .frame(width: width, alignment: .topLeading)
    .background(Color.white.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(Color(hex: "EBE6E3"), lineWidth: 1)
    )
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Text(model.seedLabel)
        .font(.custom("Figtree-Medium", size: 11))
        .foregroundStyle(Color(hex: "B16845"))

      Spacer(minLength: 12)

      controlButton("Timeline data", dataset: .timeline) {
        dataset = .timeline
      }

      controlButton("Figma baseline", dataset: .figma) {
        dataset = .figma
      }

      controlButton("Random stress", dataset: .random) {
        dataset = .random
        randomSeed = nextRandomSeed()
      }
    }
    .padding(.top, 10)
    .padding(.horizontal, 12)
    .frame(height: 33, alignment: .top)
  }

  private func controlButton(
    _ title: String,
    dataset targetDataset: WeeklySankeyDataset,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree-Medium", size: 11))
        .foregroundStyle(dataset == targetDataset ? Color(hex: "FF6B14") : Color(hex: "D77A43"))
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
              dataset == targetDataset
                ? Color(hex: "FFECD8").opacity(0.98) : Color(hex: "FCEDDF").opacity(0.72))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(
              dataset == targetDataset
                ? Color(hex: "FF7A2F").opacity(0.42)
                : Color(hex: "F7E3CF"),
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private func nextRandomSeed() -> Int {
    guard let randomSeed else { return 2417 }
    return ((randomSeed * 48271 + 12_820_163) % 99_991) + 1
  }
}

private enum WeeklySankeyDataset {
  case timeline
  case figma
  case random
}

#Preview("Weekly Sankey", traits: .fixedLayout(width: 958, height: 545)) {
  WeeklySankeySection()
    .padding(24)
    .background(Color(hex: "FBF6EF"))
}
