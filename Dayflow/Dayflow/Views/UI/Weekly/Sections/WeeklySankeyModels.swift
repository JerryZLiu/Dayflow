import SwiftUI

struct WeeklySankeyCategoryBucket {
  let id: String
  let title: String
  let colorHex: String
  let totalMinutes: Int
  let order: Int
}

struct WeeklySankeyAppBucket {
  let id: String
  let title: String
  let colorHex: String
  let iconSource: WeeklySankeyIconSource
  let raw: String?
  let host: String?
  let totalMinutes: Int
}

struct WeeklySankeyFixture {
  let columns: [SankeyColumnSpec]
  let nodes: [SankeyNodeSpec]
  let links: [SankeyLinkSpec]
  let contents: [WeeklySankeyNodeContent]

  var contentsByID: [String: WeeklySankeyNodeContent] {
    Dictionary(uniqueKeysWithValues: contents.map { ($0.id, $0) })
  }
}
