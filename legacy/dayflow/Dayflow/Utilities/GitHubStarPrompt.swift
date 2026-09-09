//
//  GitHubStarPrompt.swift
//  Dayflow
//
//  Stars the Dayflow repos through the user's `gh` CLI when it's available,
//  so the What's New prompt can star in one click instead of opening a browser.
//

import Foundation

enum GitHubStarStatus: String {
  /// `gh` is missing, not logged in, or the check failed. Fall back to the browser.
  case unavailable
  case notStarred
  case starred
}

/// Everything the star check learned, so analytics can separate "no gh" from
/// "gh but logged out" from "already starred".
struct GitHubStarCheck {
  let status: GitHubStarStatus
  let ghInstalled: Bool
  let ghAuthenticated: Bool
  /// Repo short name ("Dayflow") to whether it's starred. Empty when gh is unusable.
  let starredByRepo: [String: Bool]
  let durationMs: Int

  var analyticsProperties: [String: Any] {
    var props: [String: Any] = [
      "gh_status": status.rawValue,
      "gh_installed": ghInstalled,
      "gh_authenticated": ghAuthenticated,
      "check_duration_ms": durationMs,
    ]
    for (repo, starred) in starredByRepo {
      props["\(repo.lowercased())_starred"] = starred
    }
    return props
  }
}

struct GitHubStarResult {
  /// Repo short name to whether the PUT succeeded.
  let starredByRepo: [String: Bool]
  let durationMs: Int

  var primaryStarred: Bool {
    starredByRepo[GitHubStarPrompt.primaryRepoName] == true
  }

  var analyticsProperties: [String: Any] {
    var props: [String: Any] = [
      "repos_starred": starredByRepo.values.filter { $0 }.count,
      "star_duration_ms": durationMs,
    ]
    for (repo, succeeded) in starredByRepo {
      props["\(repo.lowercased())_star_succeeded"] = succeeded
    }
    return props
  }
}

enum GitHubStarPrompt {
  static let primaryRepo = "JerryZLiu/Dayflow"
  static let primaryRepoName = "Dayflow"
  static let primaryRepoURL = URL(string: "https://github.com/JerryZLiu/Dayflow")!

  /// Every repo a one-click star applies to.
  private static let repos = [primaryRepo, "JerryZLiu/AgentPlayback"]

  /// Starred only when every repo is starred. Blocks on shell calls, so run it off the main thread.
  static func check() -> GitHubStarCheck {
    let start = Date()
    func finish(
      _ status: GitHubStarStatus, installed: Bool, authenticated: Bool, starred: [String: Bool]
    ) -> GitHubStarCheck {
      GitHubStarCheck(
        status: status,
        ghInstalled: installed,
        ghAuthenticated: authenticated,
        starredByRepo: starred,
        durationMs: Int(Date().timeIntervalSince(start) * 1000)
      )
    }

    guard LoginShellRunner.run("gh --version", timeout: 10).exitCode == 0 else {
      return finish(.unavailable, installed: false, authenticated: false, starred: [:])
    }

    var starred: [String: Bool] = [:]
    for repo in repos {
      let result = LoginShellRunner.run("gh api user/starred/\(repo)", timeout: 10)
      if result.exitCode == 0 {
        starred[shortName(repo)] = true
        continue
      }
      // gh reports 404 on stderr when the repo is not starred.
      if result.stderr.contains("404") {
        starred[shortName(repo)] = false
        continue
      }
      // Anything else means gh can't reach GitHub as this user (logged out, offline, scope).
      let loggedOut = result.stderr.contains("auth login") || result.stderr.contains("not logged")
      return finish(.unavailable, installed: true, authenticated: !loggedOut, starred: starred)
    }

    let allStarred = starred.values.allSatisfy { $0 }
    return finish(
      allStarred ? .starred : .notStarred, installed: true, authenticated: true, starred: starred)
  }

  /// Stars every repo and reports which ones took.
  static func starAll() -> GitHubStarResult {
    let start = Date()
    var starred: [String: Bool] = [:]
    for repo in repos {
      let result = LoginShellRunner.run("gh api -X PUT user/starred/\(repo)", timeout: 10)
      starred[shortName(repo)] = result.exitCode == 0
    }
    return GitHubStarResult(
      starredByRepo: starred,
      durationMs: Int(Date().timeIntervalSince(start) * 1000)
    )
  }

  private static func shortName(_ repo: String) -> String {
    repo.split(separator: "/").last.map(String.init) ?? repo
  }
}
