//
//  FlowWaitlistView.swift
//  Dayflow
//
//  Flow tab for accounts without Flow access: a "Coming Soon" waitlist card
//  (Figma: Flow file, node 1006:21673) plus an access-code entry that unlocks
//  Flow right away. Colors are fixed because the card sits on an animated scene.
//

import SwiftUI

struct FlowWaitlistView: View {
  @ObservedObject private var authManager = DayflowAuthManager.shared

  /// Email that joined the waitlist from this Mac; empty until someone signs up.
  @AppStorage("flowWaitlistJoinedEmail") private var joinedEmail = ""
  @AppStorage("flowWaitlistJoinedAccountID") private var joinedAccountID = ""

  @State private var email = ""
  @State private var isJoining = false
  @State private var joinError: String?

  @State private var showsCodeEntry = false
  @State private var accessCode = ""
  @State private var isRedeeming = false
  @State private var codeError: String?

  private let peach = Color(hex: "FF9F6F")
  private let placeholderColor = Color(hex: "E3E3E3")
  private let errorColor = Color(hex: "FFD0C2")

  var body: some View {
    VStack(spacing: 0) {
      if !hasJoinedWaitlist {
        ZStack(alignment: .top) {
          waitlistCard
            .padding(.top, 67)
          comingSoonTitle
        }
      } else {
        FlowWaitlistChatView(
          email: joinedEmail, accountID: joinedAccountID.isEmpty ? nil : joinedAccountID
        )
        .id(joinedAccountID + ":" + joinedEmail)
        .frame(maxWidth: 680, maxHeight: 580)
      }
      accessCodeSection
        .padding(.top, 20)
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { background }
    .overlay(alignment: .topTrailing) { creatureCallout }
    .clipped()
    .onAppear {
      if email.isEmpty {
        email = hasJoinedWaitlist ? joinedEmail : (authManager.signedInEmail ?? "")
      }
      AnalyticsService.shared.screen("flow_waitlist")
    }
    .onChange(of: authManager.user?.id) {
      email = hasJoinedWaitlist ? joinedEmail : (authManager.signedInEmail ?? "")
      codeError = nil
    }
  }

  // MARK: - Background

  private var background: some View {
    FlowWaitlistBackgroundView()
      .blur(radius: 8, opaque: true)
      .overlay(Color(red: 42 / 255, green: 65 / 255, blue: 76 / 255).opacity(0.5))
  }

  // MARK: - Title and card

  private var comingSoonTitle: some View {
    Text("Coming Soon")
      .font(.custom("InstrumentSerif-Regular", size: 68))
      .tracking(-0.68)
      .foregroundStyle(
        LinearGradient(
          stops: [
            .init(color: Color(hex: "FFC49F"), location: 0.21154),
            .init(
              color: Color(red: 232 / 255, green: 244 / 255, blue: 1).opacity(0.15),
              location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .fixedSize()
      .allowsHitTesting(false)
  }

  private var waitlistCard: some View {
    VStack(spacing: 0) {
      VStack(spacing: 4) {
        Text("Join our waitlist")
          .font(.custom("InstrumentSerif-Regular", size: 28))
        Text("Get early access to Flow")
          .font(.custom("Figtree", size: 16).weight(.semibold))
      }

      Text("Flow helps you plan your day and find your way back when you get distracted.")
        .font(.custom("Figtree", size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 20)

      glassField(
        TextField(
          "", text: $email,
          prompt: Text(verbatim: "flow@dayflow.so").foregroundColor(placeholderColor)
        )
        .onSubmit(joinWaitlist)
      )
      .padding(.top, 18)

      if let joinError {
        errorText(joinError)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }

      Button(action: joinWaitlist) {
        pillLabel(
          isJoined ? String(localized: "You're on the list") : String(localized: "Sign up"),
          isLoading: isJoining,
          width: 200
        )
      }
      .buttonStyle(.plain)
      .disabled(isJoining || isJoined)
      .pointingHandCursor(enabled: !isJoined)
      .padding(.top, joinError == nil ? 27 : 12)
    }
    .foregroundColor(.white)
    .padding(.horizontal, 33.5)
    .padding(.top, 24.8)
    .padding(.bottom, 35.5)
    .frame(width: 442)
    .background(glassCardBackground)
  }

  private var glassCardBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return
      shape
      .fill(.ultraThinMaterial)
      .environment(\.colorScheme, .light)
      // Inner white glow along the edge.
      .overlay(
        shape
          .stroke(Color.white.opacity(0.3), lineWidth: 8)
          .blur(radius: 6)
          .clipShape(shape)
      )
      .overlay(shape.stroke(Color(hex: "AAAAAA"), lineWidth: 0.5))
  }

  // MARK: - Access code

  @ViewBuilder
  private var accessCodeSection: some View {
    if showsCodeEntry {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          glassField(
            TextField(
              "", text: $accessCode,
              prompt: Text("Access code").foregroundColor(placeholderColor)
            )
            .onSubmit(redeemAccessCode)
          )
          .frame(width: 200)

          Button(action: redeemAccessCode) {
            pillLabel(String(localized: "Unlock"), isLoading: isRedeeming, width: 100)
          }
          .buttonStyle(.plain)
          .disabled(isRedeeming)
          .pointingHandCursor()
        }

        if let codeError {
          errorText(codeError)
        }
      }
    } else {
      Button("Have an access code?") {
        showsCodeEntry = true
      }
      .buttonStyle(.plain)
      .font(.custom("Figtree", size: 13))
      .underline()
      .foregroundColor(.white.opacity(0.85))
      .pointingHandCursor()
    }
  }

  // MARK: - Creature

  /// The creature peeks in past the top-right edge with a speech bubble.
  /// Positions are the Figma ones, relative to the group's top-left corner.
  private var creatureCallout: some View {
    ZStack(alignment: .topLeading) {
      Image("FlowWaitlistCreature")
        .resizable()
        .frame(width: 163, height: 138)
        .rotationEffect(.degrees(-45.47))
        .frame(width: 212.688, height: 212.976)
        .offset(x: 146.26)

      // The bubble image includes its drop shadow, so it's larger than the
      // bubble itself and starts slightly up and to the left of it.
      Image("FlowWaitlistBubble")
        .resizable()
        .frame(width: 209.5, height: 64)
        .offset(x: -6, y: 93.62)

      Text("I will help you focus, and let you know when you get distracted")
        .font(.custom("Figtree", size: 13))
        .foregroundColor(Color(hex: "333333"))
        .frame(width: 156, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .offset(x: 11, y: 102)
    }
    .frame(width: 359, height: 213, alignment: .topLeading)
    .offset(x: 115, y: 22.51)
    .allowsHitTesting(false)
  }

  // MARK: - Shared pieces

  private func glassField<Field: View>(_ field: Field) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return
      field
      .textFieldStyle(.plain)
      .font(.custom("Figtree", size: 14))
      .foregroundColor(.white)
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(shape.fill(Color.white.opacity(0.2)))
      .overlay(shape.stroke(Color.white, lineWidth: 0.5))
  }

  private func pillLabel(_ title: String, isLoading: Bool, width: CGFloat) -> some View {
    ZStack {
      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Text(title)
          .font(.custom("Figtree", size: 14).weight(.medium))
      }
    }
    .foregroundColor(.white)
    .frame(width: width, height: 38)
    .background(Capsule().fill(peach))
    // Inner warm glow along the edge.
    .overlay(
      Capsule()
        .stroke(Color(red: 1, green: 220 / 255, blue: 203 / 255).opacity(0.9), lineWidth: 2)
        .blur(radius: 1.5)
        .clipShape(Capsule())
    )
    .overlay(Capsule().stroke(Color(hex: "F4C8B1"), lineWidth: 0.75))
    .contentShape(Capsule())
  }

  private func errorText(_ message: String) -> some View {
    Text(message)
      .font(.custom("Figtree", size: 12))
      .foregroundColor(errorColor)
  }

  // MARK: - Actions

  private var hasJoinedWaitlist: Bool {
    !joinedEmail.isEmpty && joinedAccountID == (authManager.user?.id ?? "")
  }

  private var isJoined: Bool {
    hasJoinedWaitlist && normalizedEmail == joinedEmail
  }

  private var normalizedEmail: String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func joinWaitlist() {
    guard !isJoining, !isJoined else { return }
    let submittedEmail = normalizedEmail
    let submittedAccountID = authManager.user?.id ?? ""
    isJoining = true
    joinError = nil

    Task {
      do {
        try await authManager.joinFlowWaitlist(email: submittedEmail)
        joinedAccountID = submittedAccountID
        joinedEmail = submittedEmail
        AnalyticsService.shared.capture(
          "flow_waitlist_joined", ["outcome": "success", "signed_in": authManager.isSignedIn])
      } catch {
        joinError = error.localizedDescription
        AnalyticsService.shared.capture(
          "flow_waitlist_joined", ["outcome": "failure", "signed_in": authManager.isSignedIn])
      }
      isJoining = false
    }
  }

  private func redeemAccessCode() {
    guard !isRedeeming else { return }
    guard authManager.isSignedIn else {
      codeError = String(localized: "Sign in under Settings › Account first, then enter your code.")
      return
    }
    isRedeeming = true
    codeError = nil

    Task {
      do {
        // On success flowEnabled flips and FlowView swaps this view for Flow.
        try await authManager.redeemFlowAccessCode(accessCode)
        AnalyticsService.shared.capture("flow_access_code_redeemed", ["outcome": "success"])
      } catch {
        codeError = error.localizedDescription
        AnalyticsService.shared.capture("flow_access_code_redeemed", ["outcome": "failure"])
      }
      isRedeeming = false
    }
  }
}
