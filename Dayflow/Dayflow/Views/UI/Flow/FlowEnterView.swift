//
//  FlowEnterView.swift
//  Dayflow
//
//  The Flow tab's front door: a short note about Flow and a button into it.
//  Signed-out users sign in from here first. Built on the old waitlist card
//  (Figma: Flow file, node 1006:21673). Colors are fixed because the card
//  sits on an animated scene.
//

import SwiftUI

struct FlowEnterView: View {
  /// Shown to accounts whose provider can't run the agent: the same page,
  /// explaining which providers Flow works with for now.
  var providerLimited = false
  /// Called when a signed-in user taps "Enter Flow".
  var onEnter: () -> Void = {}

  @ObservedObject private var authManager = DayflowAuthManager.shared

  @State private var isSignInSheetPresented = false

  private let peach = Color(hex: "FF9F6F")
  private let errorColor = Color(hex: "FFD0C2")

  var body: some View {
    ZStack(alignment: .top) {
      enterCard
        .padding(.top, 52)
      flowTitle
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { background }
    .overlay(alignment: .topTrailing) { creatureCallout }
    .clipped()
    .sheet(isPresented: $isSignInSheetPresented) {
      DayflowSignInSheet {
        isSignInSheetPresented = false
      }
      .frame(width: 430)
      // Sheets get their own window, so force light like Settings › Account does.
      .environment(\.colorScheme, .light)
      .preferredColorScheme(.light)
    }
    .onAppear {
      AnalyticsService.shared.screen(providerLimited ? "flow_provider_limited" : "flow_enter")
    }
  }

  // MARK: - Background

  private var background: some View {
    FlowWaitlistBackgroundView()
      .blur(radius: 8, opaque: true)
      .overlay(Color(red: 42 / 255, green: 65 / 255, blue: 76 / 255).opacity(0.5))
  }

  // MARK: - Title and card

  private var flowTitle: some View {
    Text("Flow")
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

  private var enterCard: some View {
    VStack(spacing: 0) {
      VStack(spacing: 4) {
        Text(providerLimited ? "Flow is limited for now" : "Plan your day, then stay on it")
          .font(.custom("InstrumentSerif-Regular", size: 28))
        if providerLimited {
          Text("For Claude, ChatGPT and Dayflow Pro users")
            .font(.custom("Figtree", size: 16).weight(.semibold))
        }
      }
      .multilineTextAlignment(.center)

      Text(
        providerLimited
          ? "Flow watches your screen during a session to keep you on track, and that takes a level of intelligence Gemini and local models can't reach yet. Switch your provider to Claude, ChatGPT or Dayflow Pro in Settings to use Flow."
          : "Pick what you want to get done and start a session. Flow watches your screen while it runs and nudges you back when you wander off."
      )
      .font(.custom("Figtree", size: 14))
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 20)

      if !providerLimited {
        enterButton
          .padding(.top, 27)

        if let notEnabledMessage {
          errorText(notEnabledMessage)
            .padding(.top, 10)
        }
      }
    }
    .foregroundColor(.white)
    .padding(.horizontal, 33.5)
    .padding(.top, 24.8)
    .padding(.bottom, 35.5)
    .frame(width: 442)
    .background(glassCardBackground)
  }

  /// "Sign in to enter" when signed out, "Enter Flow" once signed in.
  private var enterButton: some View {
    Button {
      if authManager.isSignedIn {
        AnalyticsService.shared.capture("flow_entered")
        onEnter()
      } else {
        AnalyticsService.shared.capture("flow_enter_sign_in_opened")
        isSignInSheetPresented = true
      }
    } label: {
      pillLabel(
        authManager.isSignedIn
          ? String(localized: "Enter Flow") : String(localized: "Sign in to enter"),
        width: 200
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  /// Signed in, but the backend hasn't turned Flow on for this account.
  /// Shouldn't happen once Flow is open to everyone; covers an old backend.
  private var notEnabledMessage: String? {
    guard authManager.isSignedIn, !authManager.flowEnabled else { return nil }
    return String(localized: "Flow isn't available for your account yet.")
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

  private func pillLabel(_ title: String, width: CGFloat) -> some View {
    Text(title)
      .font(.custom("Figtree", size: 14).weight(.medium))
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
}
