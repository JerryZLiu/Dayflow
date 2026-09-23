import SwiftUI

struct FlowWaitlistChatView: View {
  let email: String
  let accountID: String?

  @State private var chatUnavailable = false

  var body: some View {
    VStack(spacing: 18) {
      VStack(spacing: 6) {
        Text("You're on the waitlist")
          .font(.custom("InstrumentSerif-Regular", size: 36))
        Text(verbatim: email)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(.white.opacity(0.8))
      }
      .foregroundColor(.white)

      ZStack {
        SupportChatWebView(
          palette: .light, context: .flowWaitlist(email: email, accountID: accountID)
        ) { event in
          switch event {
          case .ready:
            chatUnavailable = false
          case .unavailable:
            chatUnavailable = true
          }
        }
        .opacity(chatUnavailable ? 0 : 1)

        if chatUnavailable {
          VStack(spacing: 12) {
            Text("You're on the list. Chat is temporarily unavailable.")
              .font(.custom("Figtree", size: 16).weight(.medium))
            Text("Come back here to tell us about yourself, or email jerry@dayflow.so.")
              .font(.custom("Figtree", size: 14))
          }
          .foregroundColor(Color(hex: "333333"))
          .multilineTextAlignment(.center)
          .padding(32)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.white.opacity(0.9))
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(.white.opacity(0.5), lineWidth: 1)
      )
    }
    .onAppear {
      SupportChatSession.flowWaitlist(email: email, accountID: accountID).setVisible(true)
    }
    .onDisappear {
      SupportChatSession.flowWaitlist(email: email, accountID: accountID).setVisible(false)
    }
  }
}
