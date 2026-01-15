import SwiftUI

struct DashboardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header (matches Timeline positioning & padding is applied on parent)
            Text("Dashboard")
                .font(.custom("InstrumentSerif-Regular", size: 42))
                .foregroundColor(.black)
                .padding(.leading, 10) // Match Timeline header inset

            // Chat interface
            ChatView()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(hex: "E8E8E8"), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
