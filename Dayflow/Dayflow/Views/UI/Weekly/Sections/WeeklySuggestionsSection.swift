import SwiftUI

struct WeeklySuggestionsSection: View {
  let snapshot: WeeklySuggestionsSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(snapshot.title)
        .font(.custom("InstrumentSerif-Regular", size: 24))
        .foregroundStyle(Color(hex: "B46531"))

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 32) {
          suggestionColumn(
            title: snapshot.topLevelUpdatesTitle,
            items: snapshot.topLevelUpdates
          )

          suggestionColumn(
            title: snapshot.nextStepsTitle,
            items: snapshot.nextSteps
          )
        }

        VStack(alignment: .leading, spacing: 24) {
          suggestionColumn(
            title: snapshot.topLevelUpdatesTitle,
            items: snapshot.topLevelUpdates
          )

          suggestionColumn(
            title: snapshot.nextStepsTitle,
            items: snapshot.nextSteps
          )
        }
      }
    }
    .padding(.horizontal, 36)
    .padding(.vertical, 28)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color.white.opacity(0.75))
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(Color(hex: "EBE6E3"), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
  }

  private func suggestionColumn(title: String, items: [WeeklySuggestionEntry]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.custom("Nunito-Bold", size: 14))
        .foregroundStyle(Color(hex: "B46531"))

      VStack(alignment: .leading, spacing: 12) {
        ForEach(items) { item in
          suggestionRow(for: item)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func suggestionRow(for item: WeeklySuggestionEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Rectangle()
        .fill(Color(hex: "FF8F64"))
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 2)

      (Text(item.label)
        .font(.custom("Nunito-Bold", size: 12))
        + Text(" - \(item.detail)")
        .font(.custom("Nunito-Regular", size: 12)))
        .foregroundStyle(Color(hex: "333333"))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct WeeklySuggestionsSnapshot {
  let title: String
  let topLevelUpdatesTitle: String
  let topLevelUpdates: [WeeklySuggestionEntry]
  let nextStepsTitle: String
  let nextSteps: [WeeklySuggestionEntry]

  static let figmaPreview = WeeklySuggestionsSnapshot(
    title: "1:1 suggestions",
    topLevelUpdatesTitle: "Top level updates",
    topLevelUpdates: [
      WeeklySuggestionEntry(
        id: "top-level-editorial-nls",
        label: "Editorial NLS",
        detail:
          "Iterated on ZSR and sparse results design explorations (zero-result states, best match redirects, query rephrasing guidance)"
      ),
      WeeklySuggestionEntry(
        id: "top-level-editorial-video-nls",
        label: "Editorial video NLS",
        detail:
          "Conducted competitive analysis of NLS video search tools (TwelveLabs, WayinVideo, AP Moments, YouTube Ask) during Pod 1 Review"
      ),
      WeeklySuggestionEntry(
        id: "top-level-editorial-sbi-1",
        label: "Editorial SBI",
        detail:
          "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
      ),
      WeeklySuggestionEntry(
        id: "top-level-editorial-sbi-2",
        label: "Editorial SBI",
        detail:
          "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
      ),
    ],
    nextStepsTitle: "Next steps",
    nextSteps: [
      WeeklySuggestionEntry(
        id: "next-steps-editorial-nls",
        label: "Editorial NLS",
        detail:
          "Iterated on ZSR and sparse results design explorations (zero-result states, best match redirects, query rephrasing guidance)"
      ),
      WeeklySuggestionEntry(
        id: "next-steps-editorial-video-nls",
        label: "Editorial video NLS",
        detail:
          "Conducted competitive analysis of NLS video search tools (TwelveLabs, WayinVideo, AP Moments, YouTube Ask) during Pod 1 Review"
      ),
      WeeklySuggestionEntry(
        id: "next-steps-editorial-sbi",
        label: "Editorial SBI",
        detail:
          "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
      ),
    ]
  )
}

struct WeeklySuggestionEntry: Identifiable {
  let id: String
  let label: String
  let detail: String
}

#Preview("1:1 Suggestions", traits: .fixedLayout(width: 958, height: 328)) {
  WeeklySuggestionsSection(snapshot: .figmaPreview)
    .padding(24)
    .background(Color(hex: "F7F3F0"))
}
