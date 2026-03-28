//
//  ChatViewModel.swift
//  Dayflow
//

import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var currentDay: String

    private let chatService = ChatLLMService()
    private var hasLoadedInitialOverview = false

    init() {
        let (dayString, _, _) = Date().getDayInfoFor4AMBoundary()
        self.currentDay = dayString
    }

    // MARK: - Day Navigation

    var isToday: Bool {
        let (todayString, _, _) = Date().getDayInfoFor4AMBoundary()
        return currentDay == todayString
    }

    var canNavigateForward: Bool {
        let (todayString, _, _) = Date().getDayInfoFor4AMBoundary()
        return currentDay < todayString
    }

    var displayDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        guard let date = formatter.date(from: currentDay) else { return currentDay }

        if isToday {
            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "MMM d"
            displayFmt.timeZone = Calendar.current.timeZone
            return "Today, \(displayFmt.string(from: date))"
        } else {
            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "EEE, MMM d"
            displayFmt.timeZone = Calendar.current.timeZone
            return displayFmt.string(from: date)
        }
    }

    func navigatePrevious() {
        guard let date = dateFromDayString(currentDay),
              let prev = Calendar.current.date(byAdding: .day, value: -1, to: date) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        loadDay(formatter.string(from: prev))
    }

    func navigateNext() {
        guard canNavigateForward else { return }
        guard let date = dateFromDayString(currentDay),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        loadDay(formatter.string(from: next))
    }

    func loadDay(_ day: String) {
        currentDay = day
        messages = []
        chatService.resetConversation()
        hasLoadedInitialOverview = false
        Task { await generateInitialOverview() }
    }

    func onAppear() {
        guard !hasLoadedInitialOverview else { return }
        hasLoadedInitialOverview = true
        Task { await generateInitialOverview() }
    }

    // MARK: - Messaging

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        inputText = ""
        messages.append(ChatMessage(role: .user, content: text))

        let loadingId = UUID()
        messages.append(ChatMessage(id: loadingId, role: .assistant, content: "", isLoading: true))
        isLoading = true

        Task {
            do {
                let response = try await chatService.sendMessage(text, day: currentDay)
                replaceMessage(id: loadingId, content: response)
            } catch {
                replaceMessage(id: loadingId, content: "Something went wrong: \(error.localizedDescription)")
            }
            isLoading = false
        }
    }

    func retryLastMessage() {
        // Find last user message
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let text = messages[lastUserIdx].content

        // Remove everything after and including the last user message
        messages = Array(messages.prefix(lastUserIdx))

        inputText = text
        sendMessage()
    }

    // MARK: - Private

    private func generateInitialOverview() async {
        let hasData = ChatDataProvider().hasDayData(day: currentDay)

        guard hasData else {
            messages.append(ChatMessage(
                role: .assistant,
                content: "No activity recorded for this day yet. Start recording to see your day here!"
            ))
            return
        }

        let loadingId = UUID()
        messages.append(ChatMessage(id: loadingId, role: .assistant, content: "", isLoading: true))
        isLoading = true

        do {
            let overview = try await chatService.generateDayOverview(day: currentDay)
            replaceMessage(id: loadingId, content: overview)
        } catch {
            replaceMessage(id: loadingId, content: "Welcome! I have your day's data loaded. Ask me anything about what you did today.")
        }

        isLoading = false
    }

    private func replaceMessage(id: UUID, content: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = content
            messages[idx].isLoading = false
        }
    }

    private func dateFromDayString(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: day)
    }
}
