import SwiftUI

struct ChatPanelView: View {
  var body: some View {
    ChatView()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
