import SwiftUI

struct JournalView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Journal")
                    .font(.custom("InstrumentSerif-Regular", size: 42))
                    .foregroundColor(.black)
                    .padding(.leading, 10)

                JournalWeeklyView()
                    .shadow(color: Color.black.opacity(0.08), radius: 30, y: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "F7F2EC").opacity(0.35))
    }
}
