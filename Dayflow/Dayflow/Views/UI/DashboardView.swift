import SwiftUI

struct DashboardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header (matches Timeline positioning & padding is applied on parent)
            Text("Dashboard")
                .font(.custom("InstrumentSerif-Regular", size: 42))
                .foregroundColor(Color(hex: "1F1C17"))
                .padding(.leading, 10) // Match Timeline header inset

            // Chat interface
            ChatView()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(hex: "FFFAF5")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "E9DDD0"), lineWidth: 1)
                )
                .shadow(color: Color(hex: "D99A5A").opacity(0.14), radius: 16, x: 0, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
