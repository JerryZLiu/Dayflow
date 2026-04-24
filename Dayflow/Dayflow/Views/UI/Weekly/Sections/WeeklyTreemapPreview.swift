import SwiftUI

#Preview("Weekly Treemap", traits: .fixedLayout(width: 958, height: 549)) {
  WeeklyTreemapPreviewHarness()
    .background(Color(hex: "F7F3F0"))
}

struct WeeklyTreemapPreviewHarness: View {
  @State var selectedDataset = WeeklyTreemapPreviewDataset.balanced

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        ForEach(WeeklyTreemapPreviewDataset.allCases) { dataset in
          Button {
            selectedDataset = dataset
          } label: {
            Text(dataset.title)
              .font(.custom("Nunito-Regular", size: 12))
              .foregroundStyle(selectedDataset == dataset ? Color.white : Color(hex: "7C5A46"))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                Capsule(style: .continuous)
                  .fill(
                    selectedDataset == dataset ? Color(hex: "B46531") : Color.white.opacity(0.75))
              )
              .overlay(
                Capsule(style: .continuous)
                  .stroke(Color(hex: "E3D6CF"), lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
        }
      }

      WeeklyTreemapSection(snapshot: selectedDataset.snapshot)
    }
    .padding(18)
  }
}

enum WeeklyTreemapPreviewDataset: String, CaseIterable, Identifiable {
  case balanced
  case dominant
  case tinyTail
  case crowded

  var id: String { rawValue }

  var title: String {
    switch self {
    case .balanced:
      return "Balanced"
    case .dominant:
      return "Dominant"
    case .tinyTail:
      return "Tiny Tail"
    case .crowded:
      return "Crowded"
    }
  }

  var snapshot: WeeklyTreemapSnapshot {
    switch self {
    case .balanced:
      return .figmaPreview
    case .dominant:
      return .dominantCategoryPreview
    case .tinyTail:
      return .tinyTailPreview
    case .crowded:
      return .crowdedPreview
    }
  }
}
