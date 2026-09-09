//
//  JournalBoardLayout.swift
//  Dayflow
//
//  The two-card journal board: intentions/notes/goals on the left, a
//  caller-provided card (reflection, summary, ...) on the right.
//

import SwiftUI

struct JournalBoardLayout<RightContent: View>: View {
  var intentions: [String]
  var notes: String
  var goals: [String]
  var onTapLeft: (() -> Void)?

  var isUnfolding: Bool
  var namespace: Namespace.ID?
  @State private var rotationAngle: Double
  @State private var opacity: Double

  var rightContent: RightContent

  init(
    intentions: [String],
    notes: String,
    goals: [String],
    onTapLeft: (() -> Void)? = nil,
    isUnfolding: Bool = false,
    namespace: Namespace.ID? = nil,
    @ViewBuilder rightContent: () -> RightContent
  ) {
    self.intentions = intentions
    self.notes = notes
    self.goals = goals
    self.onTapLeft = onTapLeft
    self.isUnfolding = isUnfolding
    self.namespace = namespace
    self.rightContent = rightContent()

    _rotationAngle = State(initialValue: isUnfolding ? -90 : 0)
    _opacity = State(initialValue: isUnfolding ? 0 : 1)
  }

  var body: some View {
    HStack(spacing: 0) {
      JournalLeftCardView(
        intentions: intentions, notes: notes, goals: goals, onTap: onTapLeft, namespace: namespace
      )
      .zIndex(1)

      JournalRightCard { rightContent }
        .opacity(opacity)
        .rotation3DEffect(
          .degrees(rotationAngle),
          axis: (x: 0, y: 1, z: 0),
          anchor: .leading,
          anchorZ: 0,
          perspective: 0.5
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear {
      if isUnfolding {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.6)) {
          rotationAngle = 0
          opacity = 1
        }
      }
    }
  }
}

private struct JournalLeftCardView: View {
  var intentions: [String]
  var notes: String
  var goals: [String]
  var onTap: (() -> Void)?
  var namespace: Namespace.ID?

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 18) {
        section("Today's intentions") {
          JournalDayBulletList(items: intentions)
        }
        section("Notes for the day") {
          Text(notes.isEmpty ? "—" : notes)
            .font(.custom("Figtree-Regular", size: 15))
            .foregroundStyle(
              notes.isEmpty ? JournalDayTokens.bodyText.opacity(0.4) : JournalDayTokens.bodyText)
        }
        Divider()
          .foregroundStyle(JournalDayTokens.divider)
          .overlay(JournalDayTokens.divider)
          .padding(.vertical, 6)
        section("Long term goals") {
          JournalDayBulletList(items: goals)
        }
        Spacer(minLength: 0)
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      LinearGradient(
        stops: [
          .init(color: Color.white.opacity(0.3), location: 0.00),
          .init(color: Color.white.opacity(0.8), location: 0.51),
          .init(color: Color.white.opacity(0.3), location: 1.00),
        ],
        startPoint: UnitPoint(x: 1, y: 0.14),
        endPoint: UnitPoint(x: 0, y: 0.78)
      )
    )
    .cornerRadius(12)
    .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .inset(by: 0.5)
        .stroke(Color.white, lineWidth: 1)
    )
    .applyIf(namespace != nil) { view in
      view.matchedGeometryEffect(id: "card_bg", in: namespace!)
    }
    .modifier(PaperHoverEffect(isEnabled: onTap != nil))
    .contentShape(Rectangle())
    .onTapGesture {
      onTap?()
    }
    .pointingHandCursor(enabled: onTap != nil)
  }

  @ViewBuilder
  private func section(_ title: String, content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.custom("InstrumentSerif-Regular", size: 20))
        .foregroundStyle(JournalDayTokens.sectionHeader)
      content()
    }
  }
}

private struct JournalRightCard<Content: View>: View {
  var content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 18) { content }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.white.opacity(0.92))
    .cornerRadius(12)
    .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.white.opacity(0.8), lineWidth: 1)
    )
  }
}
