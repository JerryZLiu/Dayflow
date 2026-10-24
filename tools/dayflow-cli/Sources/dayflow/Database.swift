//
//  Database.swift
//  dayflow-cli
//
//  Read-only access to Dayflow's SQLite database. Read-only is enforced at the
//  connection level (SQLITE_OPEN_READONLY + PRAGMA query_only), not by command
//  naming, so a bug in this tool cannot corrupt the app's data.
//

import Foundation
#if os(Linux)
import CSQLite
#else
import SQLite3
#endif

// sqlite3_bind_text needs SQLITE_TRANSIENT, which the Swift importer can't
// express directly because it's a C macro casting -1 to a function pointer.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error {
  case notFound(String)
  case cannotOpen(String)
  case queryFailed(String)
}

/// A single row, keyed by column name.
struct SQLRow {
  private let values: [String: SQLValue]

  init(values: [String: SQLValue]) {
    self.values = values
  }

  func int(_ column: String) -> Int? {
    if case .integer(let v)? = values[column] { return Int(v) }
    return nil
  }

  func string(_ column: String) -> String? {
    if case .text(let v)? = values[column] { return v }
    return nil
  }
}

enum SQLValue {
  case integer(Int64)
  case real(Double)
  case text(String)
  case null
}

final class Database {
  private let handle: OpaquePointer

  /// Dayflow's database location. Overridable via DAYFLOW_DB for tests.
  static func defaultPath() -> String {
    if let override = ProcessInfo.processInfo.environment["DAYFLOW_DB"] {
      return override
    }
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Dayflow/chunks.sqlite").path
  }

  init(path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else {
      throw DatabaseError.notFound(path)
    }

    var db: OpaquePointer?
    // Read-only, and no implicit creation. The app keeps the database in WAL
    // mode, so concurrent reads while the app writes are safe.
    let flags = SQLITE_OPEN_READONLY
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let db { sqlite3_close(db) }
      throw DatabaseError.cannotOpen(message)
    }
    handle = db

    // Belt and suspenders on top of the read-only open.
    sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)
    // Don't fail instantly if the app is mid-checkpoint.
    sqlite3_busy_timeout(handle, 2000)
  }

  deinit {
    sqlite3_close(handle)
  }

  func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }

    for (index, value) in bindings.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case .integer(let v): sqlite3_bind_int64(statement, position, v)
      case .real(let v): sqlite3_bind_double(statement, position, v)
      case .text(let v): sqlite3_bind_text(statement, position, v, -1, sqliteTransient)
      case .null: sqlite3_bind_null(statement, position)
      }
    }

    var rows: [SQLRow] = []
    while true {
      let stepResult = sqlite3_step(statement)
      if stepResult == SQLITE_DONE { break }
      guard stepResult == SQLITE_ROW else {
        throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
      }

      var values: [String: SQLValue] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
          values[name] = .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
          values[name] = .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
          values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
        default:
          values[name] = .null
        }
      }
      rows.append(SQLRow(values: values))
    }
    return rows
  }
}
