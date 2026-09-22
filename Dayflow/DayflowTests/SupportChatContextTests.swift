import XCTest

@testable import Dayflow

final class SupportChatContextTests: XCTestCase {
  func testTheSameWaitlistEmailCannotShareAConversationAcrossAccounts() {
    let email = "person@example.com"
    let contexts: [SupportChatContext] = [
      .support,
      .flowWaitlist(email: email),
      .flowWaitlist(email: email, accountID: "account-a"),
      .flowWaitlist(email: email, accountID: "account-b"),
    ]

    XCTAssertEqual(Set(contexts.map(\.sessionKey)).count, contexts.count)
  }

  func testReturningToTheSameAccountAndEmailKeepsTheConversation() {
    let original = SupportChatContext.flowWaitlist(
      email: "person@example.com", accountID: "account-a")
    let enteredAgain = SupportChatContext.flowWaitlist(
      email: " Person@Example.com \n", accountID: " account-a ")

    XCTAssertEqual(original.sessionKey, enteredAgain.sessionKey)
    XCTAssertEqual(enteredAgain.email, "person@example.com")
    XCTAssertEqual(enteredAgain.accountID, "account-a")
  }

  func testWaitlistEmailsWithinTheSameAccountStaySeparate() {
    let first = SupportChatContext.flowWaitlist(
      email: "first@example.com", accountID: "account-a")
    let second = SupportChatContext.flowWaitlist(
      email: "second@example.com", accountID: "account-a")

    XCTAssertNotEqual(first.sessionKey, second.sessionKey)
  }

  func testAnEmptyAccountIDUsesTheSignedOutConversation() {
    let anonymous = SupportChatContext.flowWaitlist(email: "person@example.com")
    let empty = SupportChatContext.flowWaitlist(email: "person@example.com", accountID: " \n")

    XCTAssertEqual(anonymous.sessionKey, empty.sessionKey)
    XCTAssertNil(empty.accountID)
  }
}
