import XCTest

@testable import Dayflow

@MainActor
final class ChatDraftTests: XCTestCase {
  func testDraftInputPersistsOnChatServiceAcrossViewRecreation() {
    let service = ChatService()

    service.draftInputText = "Summarize yesterday's work"

    XCTAssertEqual(service.draftInputText, "Summarize yesterday's work")
  }

  func testClearConversationClearsDraftInput() {
    let service = ChatService()
    service.draftInputText = "Unsent question"

    service.clearConversation()

    XCTAssertEqual(service.draftInputText, "")
  }
}
