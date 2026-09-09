import AppKit
import SwiftUI
import WebKit

struct AgentPlaybackView: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var host = AgentPlaybackHost.shared
  @AppStorage("agentsOnboardingCompleted") private var onboardingCompleted = false
  @State private var setupStarted = false

  var body: some View {
    Group {
      if !onboardingCompleted {
        onboarding
      } else if let webView = host.webView {
        AgentPlaybackWebView(webView: webView, isDark: theme.isDark)
      } else {
        VStack(spacing: 16) {
          Text("Agents")
            .font(.title)
          if let error = host.error {
            Text(error)
              .multilineTextAlignment(.center)
              .textSelection(.enabled)
              .frame(maxWidth: 480)
            Button("Try again") {
              AnalyticsService.shared.capture("agentplayback_retry_clicked")
              host.start()
            }
            Link("Install Node.js", destination: URL(string: "https://nodejs.org/en/download")!)
          } else {
            ProgressView()
            Text("Starting AgentPlayback…")
            Text("The first launch downloads AgentPlayback. Node.js and npm are required.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      host.usage.appear(foreground: NSApp.isActive)
      setupStarted = host.hasStarted
      if onboardingCompleted { host.startIfNeeded() }
    }
    .onDisappear { host.usage.disappear() }
  }

  private var onboarding: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Image("AgentsIcon")
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .frame(width: 48, height: 48)
          .foregroundStyle(Color.accentColor)
        Text(
          setupStarted
            ? (host.isReady ? "Your dashboard is ready" : "Set up Agents")
            : "See how your agents spend their time"
        )
        .font(.system(size: 28, weight: .semibold))
        Text("A timeline of your Codex and Claude Code sessions, right here in Dayflow.")
          .font(.title3)
          .foregroundStyle(.secondary)

        if !setupStarted {
          onboardingDetail(
            "Working or waiting", "See when your agents are running and when they need your input.")
          onboardingDetail(
            "Your day, across projects", "Review sessions, token usage, and estimated API cost.")
          onboardingDetail(
            "From logs on this Mac",
            "Agents reads existing Codex and Claude Code session logs and processes them locally. No API key is needed."
          )
          Button("Set up Agents") {
            setupStarted = true
            host.startIfNeeded()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        } else if let error = host.error {
          Text("We couldn’t start Agents")
            .font(.headline)
          Text(error)
            .font(.callout)
            .textSelection(.enabled)
          HStack {
            Button("Try again") { host.start() }
              .buttonStyle(.borderedProminent)
            Link("Install Node.js", destination: URL(string: "https://nodejs.org/en/download")!)
          }
          Text("After installing Node.js, return here and try again.")
            .foregroundStyle(.secondary)
        } else if host.isReady {
          onboardingDetail(
            "Start with today",
            "Open the dashboard to explore your activity. Choose an earlier date to review past sessions."
          )
          onboardingDetail(
            "Don’t see any activity?",
            "Run a task in Codex or Claude Code on this Mac, then return to Agents. Initial processing can take a little time."
          )
          Button("Open Agents") { onboardingCompleted = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
          HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Preparing your local dashboard…")
          }
          Text(
            "The first launch downloads AgentPlayback. You can switch tabs while setup finishes."
          )
          .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: 520, alignment: .leading)
      .padding(48)
      .frame(maxWidth: .infinity, minHeight: 540)
    }
  }

  private func onboardingDetail(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

}

private struct AgentPlaybackWebView: NSViewRepresentable {
  let webView: WKWebView
  let isDark: Bool

  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {
    AgentPlaybackAppearance.apply(to: nsView, isDark: isDark)
  }
}

/// Owns one server and WebView for the app session, including across tab switches.
@MainActor
final class AgentPlaybackHost: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  static let shared = AgentPlaybackHost()
  @Published private(set) var webView: WKWebView?
  @Published private(set) var error: String?
  @Published private(set) var isReady = false

  private var process: Process?
  private var serverPID: Int32?
  private var attempt = UUID()
  private var output = ""
  private var pendingOutput = ""
  private var leaseURL: URL?
  private var pageLoaded = false
  private var version: String?
  private var isFallback = false
  private var timeout: Task<Void, Never>?
  private var origin: URL?
  private let versionKey = "agentPlaybackLastWorkingVersion"
  let usage = AgentPlaybackUsage()
  private var launchStartedAt: TimeInterval?

  private enum FailureCategory: String {
    case preparation
    case processLaunch = "process_launch"
    case processExit = "process_exit"
    case missingRuntime = "missing_runtime"
    case timeout
    case navigation
    case webContentTerminated = "web_content_terminated"
  }

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(terminate), name: NSApplication.willTerminateNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(resignedActive), name: NSApplication.didResignActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(consentChanged), name: .analyticsPreferenceChanged, object: nil)
  }

  @objc private func becameActive() { usage.setForeground(true) }
  @objc private func resignedActive() { usage.setForeground(false) }
  @objc private func consentChanged() { usage.consentChanged() }
  @objc private func terminate() {
    usage.terminate()
    stop()
  }

  var hasStarted: Bool { process != nil || error != nil }

  func startIfNeeded() {
    if process == nil && error == nil { start() }
  }

  func start() { launch(version: "latest", offline: false) }

  private func launch(version requestedVersion: String, offline: Bool) {
    stop()
    error = nil
    output = ""
    pendingOutput = ""
    pageLoaded = false
    version = nil
    isFallback = offline
    launchStartedAt = ProcessInfo.processInfo.systemUptime
    AnalyticsService.shared.capture(
      "agentplayback_launch_started",
      [
        "mode": offline ? "cached_fallback" : "latest"
      ])
    let id = attempt
    let process = Process()
    let pipe = Pipe()
    process.executableURL = LoginShellRunner.userLoginShell
    // Resolve the actual npm package entrypoint before launching a separate process
    // group, so cleanup also reaches the scanner's children and worker processes.
    let wrapper = """
      const fs = require('node:fs');
      const path = require('node:path');
      const { spawn } = require('node:child_process');
      const lease = process.env.DAYFLOW_AGENT_LEASE;
      const hostIsAlive = () => {
        try { process.kill(Number(process.env.DAYFLOW_AGENT_HOST_PID), 0); return fs.existsSync(lease); }
        catch { return false; }
      };
      if (!lease || !hostIsAlive()) process.exit(0);
      const cli = fs.realpathSync(process.argv[1]);
      const pkg = JSON.parse(fs.readFileSync(path.join(path.dirname(cli), '..', 'package.json'), 'utf8'));
      console.log('DAYFLOW_AGENT_VERSION=' + pkg.version);
      const child = spawn(process.execPath, [cli, '--no-open'], { detached: true, stdio: 'inherit' });
      console.log('DAYFLOW_AGENT_PID=' + child.pid);
      const stop = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
      process.on('SIGTERM', () => { stop(); process.exit(0); });
      process.on('SIGINT', () => { stop(); process.exit(0); });
      setInterval(() => {
        if (!hostIsAlive()) { stop(); try { fs.unlinkSync(lease); } catch {} process.exit(0); }
      }, 1000).unref();
      child.on('error', err => { console.error(err.message); process.exit(1); });
      child.on('exit', code => { stop(); process.exit(code ?? 1); });
      """
    let command = "node -e \(LoginShellRunner.shellEscape(wrapper)) \"$(command -v agentplayback)\""
    let package = LoginShellRunner.shellEscape("agentplayback@\(requestedVersion)")
    process.arguments = [
      "-l", "-i", "-c",
      """
      command -v node >/dev/null && command -v npx >/dev/null || { echo 'Node.js and npm were not found. Install Node.js, then try again.'; exit 127; }
      exec npx --yes \(offline ? "--offline" : "--prefer-online") --package=\(package) -c \(LoginShellRunner.shellEscape(command))
      """,
    ]
    var environment = ProcessInfo.processInfo.environment
    let dataDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow/agents", isDirectory: true)
    environment["AGENTPLAYBACK_HOME"] = dataDirectory.path
    let lease = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dayflow-agents-\(id)")
    do {
      try Data().write(to: lease)
    } catch {
      fail("Couldn’t prepare AgentPlayback: \(error.localizedDescription)", category: .preparation)
      return
    }
    leaseURL = lease
    environment["DAYFLOW_AGENT_LEASE"] = lease.path
    environment["DAYFLOW_AGENT_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)
    environment["npm_config_update_notifier"] = "false"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    self.process = process
    do {
      try process.run()
    } catch {
      fail("Couldn’t start AgentPlayback: \(error.localizedDescription)", category: .processLaunch)
      return
    }
    Task.detached { [weak self] in
      let handle = pipe.fileHandleForReading
      while true {
        let data = handle.availableData
        if data.isEmpty { break }
        await self?.receive(String(decoding: data, as: UTF8.self), attempt: id)
      }
      process.waitUntilExit()
      await self?.exited(attempt: id, status: process.terminationStatus)
    }
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(120)) } catch { return }
      guard let self, self.attempt == id, !self.pageLoaded else { return }
      self.fail(
        "AgentPlayback took too long to start. Check your connection and try again.",
        category: .timeout)
    }
  }

  private func receive(_ text: String, attempt id: UUID) {
    guard id == attempt else { return }
    output += text
    pendingOutput += text
    // The CLI emits a human-readable URL; match only the explicit startup line.
    while let newline = pendingOutput.firstIndex(of: "\n") {
      let line = String(pendingOutput[..<newline])
      pendingOutput.removeSubrange(...newline)
      if line.hasPrefix("DAYFLOW_AGENT_VERSION=") {
        let candidate = String(line.dropFirst("DAYFLOW_AGENT_VERSION=".count))
        if candidate.range(
          of: #"^\d+\.\d+\.\d+([-+][a-zA-Z0-9.-]+)?$"#, options: .regularExpression) != nil
        {
          version = candidate
        }
      }
      if line.hasPrefix("DAYFLOW_AGENT_PID="),
        let pid = Int32(line.dropFirst("DAYFLOW_AGENT_PID=".count)), pid > 1
      {
        serverPID = pid
      }
      if webView == nil,
        let range = line.range(
          of: #"agentplayback is running at http://localhost:[0-9]+/"#, options: .regularExpression),
        let port = Int(line[range].split(separator: ":").last?.dropLast() ?? ""),
        (1...65535).contains(port),
        let url = URL(string: "http://127.0.0.1:\(port)/")
      {
        origin = url
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.configuration.userContentController.addUserScript(
          WKUserScript(
            source: AgentPlaybackAppearance.script, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        view.load(URLRequest(url: url))
      }
    }
    output = String(output.suffix(16000))
    pendingOutput = String(pendingOutput.suffix(16000))
  }

  private func exited(attempt id: UUID, status: Int32) {
    guard id == attempt else { return }
    fail(
      "AgentPlayback stopped.\n\n\(output.suffix(2000))",
      category: status == 127 && version == nil ? .missingRuntime : .processExit)
  }

  private func fail(_ message: String, category: FailureCategory) {
    var properties = launchProperties
    properties["failure_category"] = category.rawValue
    properties["will_try_fallback"] =
      !isFallback && UserDefaults.standard.string(forKey: versionKey) != nil
    if launchStartedAt != nil {
      properties["outcome"] = "failure"
      AnalyticsService.shared.capture("agentplayback_launch_completed", properties)
      launchStartedAt = nil
    } else {
      AnalyticsService.shared.capture("agentplayback_runtime_failed", properties)
    }
    if !isFallback, let saved = UserDefaults.standard.string(forKey: versionKey) {
      launch(version: saved, offline: true)
    } else {
      stop()
      error = message
    }
  }

  @objc private func stop() {
    isReady = false
    usage.setReady(false)
    attempt = UUID()
    timeout?.cancel()
    timeout = nil
    if let leaseURL { try? FileManager.default.removeItem(at: leaseURL) }
    leaseURL = nil
    if let serverPID { kill(-serverPID, SIGKILL) }
    serverPID = nil
    if let process, process.isRunning { process.terminate() }
    process = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView = nil
    origin = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    if launchStartedAt != nil {
      var properties = launchProperties
      properties["outcome"] = "success"
      AnalyticsService.shared.capture("agentplayback_launch_completed", properties)
      launchStartedAt = nil
    }
    pageLoaded = true
    isReady = true
    usage.setReady(true)
    timeout?.cancel()
    if let version { UserDefaults.standard.set(version, forKey: versionKey) }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard webView === self.webView else { return }
    fail("Couldn’t load AgentPlayback: \(error.localizedDescription)", category: .navigation)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    fail("AgentPlayback’s window stopped responding. Try again.", category: .webContentTerminated)
  }

  private var launchProperties: [String: Any] {
    var properties: [String: Any] = ["mode": isFallback ? "cached_fallback" : "latest"]
    if let version { properties["agentplayback_version"] = version }
    if let launchStartedAt {
      properties["duration_seconds"] =
        ((ProcessInfo.processInfo.systemUptime - launchStartedAt) * 10).rounded() / 10
    }
    return properties
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.scheme == origin?.scheme && url.host == origin?.host && url.port == origin?.port {
      decisionHandler(.allow)
    } else {
      if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
      decisionHandler(.cancel)
    }
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, ["https", "http"].contains(url.scheme ?? "") {
      NSWorkspace.shared.open(url)
    }
    return nil
  }
}
