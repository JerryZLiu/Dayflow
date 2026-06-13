import Foundation
import GRDB

/// Summary row for the chat history panel.
struct ChatConversationRecord: Identifiable, Sendable, Equatable {
  let id: UUID
  var title: String
  var provider: String
  var cliSessionId: String?
  let createdAt: Date
  var updatedAt: Date
}

extension StorageManager {
  // MARK: - Chat History Methods

  /// Upsert a conversation and replace its messages in one transaction.
  /// Conversations are small, so replace-all keeps persistence idempotent
  /// without any dirty-tracking in ChatService.
  func saveChatConversation(_ record: ChatConversationRecord, messages: [ChatMessage]) {
    try? timedWrite("saveChatConversation") { db in
      try db.execute(
        sql: """
              INSERT INTO chat_conversations (id, title, provider, cli_session_id, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                  title = excluded.title,
                  provider = excluded.provider,
                  cli_session_id = excluded.cli_session_id,
                  updated_at = excluded.updated_at
          """,
        arguments: [
          record.id.uuidString,
          record.title,
          record.provider,
          record.cliSessionId,
          Int(record.createdAt.timeIntervalSince1970),
          Int(record.updatedAt.timeIntervalSince1970),
        ])

      try db.execute(
        sql: "DELETE FROM chat_messages WHERE conversation_id = ?",
        arguments: [record.id.uuidString])

      for (index, message) in messages.enumerated() {
        try db.execute(
          sql: """
                INSERT INTO chat_messages (id, conversation_id, role, content, created_at, sort_order)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            message.id.uuidString,
            record.id.uuidString,
            message.role.rawValue,
            message.content,
            Int(message.timestamp.timeIntervalSince1970),
            index,
          ])
      }
    }
  }

  func fetchChatConversations() -> [ChatConversationRecord] {
    return
      (try? timedRead("fetchChatConversations") { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
                SELECT id, title, provider, cli_session_id, created_at, updated_at
                FROM chat_conversations
                ORDER BY updated_at DESC
            """)

        return rows.compactMap { row -> ChatConversationRecord? in
          guard let id = UUID(uuidString: row["id"]) else { return nil }
          return ChatConversationRecord(
            id: id,
            title: row["title"],
            provider: row["provider"],
            cliSessionId: row["cli_session_id"],
            createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int64)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at"] as Int64))
          )
        }
      }) ?? []
  }

  func fetchChatMessages(conversationId: UUID) -> [ChatMessage] {
    return
      (try? timedRead("fetchChatMessages") { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
                SELECT id, role, content, created_at
                FROM chat_messages
                WHERE conversation_id = ?
                ORDER BY sort_order ASC
            """, arguments: [conversationId.uuidString])

        return rows.compactMap { row -> ChatMessage? in
          guard let id = UUID(uuidString: row["id"]),
            let role = ChatMessage.Role(rawValue: row["role"])
          else { return nil }
          return ChatMessage(
            id: id,
            role: role,
            content: row["content"],
            timestamp: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int64))
          )
        }
      }) ?? []
  }

  func deleteChatConversation(id: UUID) {
    try? timedWrite("deleteChatConversation") { db in
      // Delete messages explicitly in case foreign keys are disabled.
      try db.execute(
        sql: "DELETE FROM chat_messages WHERE conversation_id = ?",
        arguments: [id.uuidString])
      try db.execute(
        sql: "DELETE FROM chat_conversations WHERE id = ?",
        arguments: [id.uuidString])
    }
  }
}
