import Foundation

enum StoragePathMigrator {
  private static let migrationFlagKey = "didMigrateFromSandbox"

  static func migrateIfNeeded() {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: migrationFlagKey) {
      print("ℹ️ StoragePathMigrator: skipping – already migrated")
      return
    }

    guard let bundleID = Bundle.main.bundleIdentifier else {
      print("⚠️ StoragePathMigrator: missing bundle identifier, marking migration as complete")
      defaults.set(true, forKey: migrationFlagKey)
      return
    }

    let fileManager = FileManager.default
    let legacyBase = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Containers/\(bundleID)/Data/Library/Application Support/Dayflow", isDirectory: true
      )

    guard fileManager.fileExists(atPath: legacyBase.path) else {
      print(
        "ℹ️ StoragePathMigrator: sandbox container absent at \(legacyBase.path); nothing to migrate")
      defaults.set(true, forKey: migrationFlagKey)
      return
    }

    guard
      let newSupport = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else {
      print("⚠️ StoragePathMigrator: unable to resolve unsandboxed Application Support directory")
      return
    }

    let destinationBase = newSupport.appendingPathComponent("Dayflow", isDirectory: true)

    let normalizedLegacy = legacyBase.standardizedFileURL.path
    let normalizedDestination = destinationBase.standardizedFileURL.path

    if normalizedLegacy == normalizedDestination {
      print("ℹ️ StoragePathMigrator: source and destination are identical; skipping migration")
      defaults.set(true, forKey: migrationFlagKey)
      return
    }

    do {
      try fileManager.createDirectory(at: destinationBase, withIntermediateDirectories: true)
      try relocateDirectoryContents(from: legacyBase, to: destinationBase, fileManager: fileManager)
      try? fileManager.removeItem(at: legacyBase)
      print(
        "ℹ️ StoragePathMigrator: migrated data from sandbox container to \(destinationBase.path)")
      defaults.set(true, forKey: migrationFlagKey)
    } catch {
      print("⚠️ StoragePathMigrator: migration failed with error: \(error)")
    }
  }

  private static func relocateDirectoryContents(
    from source: URL, to destination: URL, fileManager: FileManager
  ) throws {
    let contents = try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )

    for item in contents {
      let target = destination.appendingPathComponent(item.lastPathComponent)
      let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])

      if values.isDirectory == true {
        if !fileManager.fileExists(atPath: target.path) {
          try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        try relocateDirectoryContents(from: item, to: target, fileManager: fileManager)
        try? fileManager.removeItem(at: item)
        continue
      }

      if fileManager.fileExists(atPath: target.path) {
        let existingSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let incomingSize = values.fileSize ?? 0

        if existingSize < incomingSize {
          try fileManager.removeItem(at: target)
          try fileManager.moveItem(at: item, to: target)
        } else {
          try fileManager.removeItem(at: item)
        }
      } else {
        let parent = target.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
          try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: item, to: target)
      }
    }
  }
}
