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
            ? (host.isReady
              ? String(localized: "Your dashboard is ready") : String(localized: "Set up Agents"))
            : String(localized: "See how your agents spend their time")
        )
        .font(.system(size: 28, weight: .semibold))
        Text("A timeline of your Codex and Claude Code sessions, right here in Dayflow.")
          .font(.title3)
          .foregroundStyle(.secondary)

        if !setupStarted {
          onboardingDetail(
            String(localized: "Working or waiting"),
            String(localized: "See when your agents are running and when they need your input."))
          onboardingDetail(
            String(localized: "Your day, across projects"),
            String(localized: "Review sessions, token usage, and estimated API cost."))
          onboardingDetail(
            String(localized: "From logs on this Mac"),
            String(
              localized:
                "Agents reads existing Codex and Claude Code session logs and processes them locally. No API key is needed."
            )
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
            String(localized: "Start with today"),
            String(
              localized:
                "Open the dashboard to explore your activity. Choose an earlier date to review past sessions."
            )
          )
          onboardingDetail(
            String(localized: "Don’t see any activity?"),
            String(
              localized:
                "Run a task in Codex or Claude Code on this Mac, then return to Agents. Initial processing can take a little time."
            )
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
  private var attemptStartedAt = ProcessInfo.processInfo.systemUptime
  private var requestedVersion = "latest"
  private var fallbackFromAttempt: String?

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

  func start() {
    fallbackFromAttempt = nil
    launch(version: "latest", offline: false)
  }

  private func launch(version requestedVersion: String, offline: Bool) {
    stop()
    error = nil
    output = ""
    pendingOutput = ""
    pageLoaded = false
    version = nil
    isFallback = offline
    self.requestedVersion = requestedVersion
    attemptStartedAt = ProcessInfo.processInfo.systemUptime
    launchStartedAt = attemptStartedAt
    AnalyticsService.shared.capture(
      "agentplayback_launch_started",
      launchProperties)
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
      const cli = fs.realpathSync(process.argv[process.argv.length - 1]);
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
      console.log('DAYFLOW_NODE=' + process.version + ' executable=' + process.execPath + ' cli=' + cli);
      child.on('error', err => { console.error(err.stack ?? err.message); process.exit(1); });
      child.on('exit', (code, signal) => { console.error('DAYFLOW_CHILD_EXIT code=' + code + ' signal=' + signal); stop(); process.exit(code ?? 1); });
      """
    let dataDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow/agents", isDirectory: true)
    // Run the wrapper from a file instead of `node -e`: some endpoint security tools
    // (e.g. SentinelOne) kill processes whose arguments look like overly long paths.
    // If the file can't be written, fall back to the inline script.
    let wrapperArgument: String
    do {
      let launcher = dataDirectory.appendingPathComponent("launcher.cjs")
      try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
      try wrapper.write(to: launcher, atomically: true, encoding: .utf8)
      wrapperArgument = LoginShellRunner.shellEscape(launcher.path)
    } catch {
      wrapperArgument = "-e \(LoginShellRunner.shellEscape(wrapper))"
    }
    let command = "node \(wrapperArgument) \"$(command -v agentplayback)\""
    let package = LoginShellRunner.shellEscape("agentplayback@\(requestedVersion)")
    process.arguments = [
      "-l", "-i", "-c",
      """
      command -v node >/dev/null && command -v npx >/dev/null || { echo 'Node.js and npm were not found. Install Node.js, then try again.'; exit 127; }
      exec npx --yes \(offline ? "--offline" : "--prefer-online") --package=\(package) -c \(LoginShellRunner.shellEscape(command))
      """,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["AGENTPLAYBACK_HOME"] = dataDirectory.path
    let lease = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dayflow-agents-\(id)")
    do {
      try Data().write(to: lease)
    } catch {
      fail(
        String(localized: "Couldn’t prepare AgentPlayback: \(error.localizedDescription)"),
        category: .preparation,
        diagnostics: errorProperties(error))
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
      fail(
        String(localized: "Couldn’t start AgentPlayback: \(error.localizedDescription)"),
        category: .processLaunch,
        diagnostics: errorProperties(error))
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
      await self?.exited(
        attempt: id, status: process.terminationStatus,
        reason: process.terminationReason == .uncaughtSignal ? "signal" : "exit")
    }
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(120)) } catch { return }
      guard let self, self.attempt == id, !self.pageLoaded else { return }
      self.fail(
        String(
          localized: "AgentPlayback took too long to start. Check your connection and try again."),
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

  private func exited(attempt id: UUID, status: Int32, reason: String) {
    guard id == attempt else { return }
    fail(
      String(localized: "AgentPlayback stopped (\(reason) \(status)).\n\n\(output.suffix(2000))"),
      category: status == 127 && version == nil ? .missingRuntime : .processExit,
      diagnostics: ["termination_status": Int(status), "termination_reason": reason])
  }

  private func fail(
    _ message: String, category: FailureCategory, diagnostics: [String: Any] = [:]
  ) {
    var properties = launchProperties
    properties.merge(diagnostics) { _, new in new }
    properties["startup_stage"] =
      pageLoaded
      ? "page_loaded"
      : (origin != nil ? "url_received" : (version != nil ? "package_resolved" : "shell_or_npx"))
    properties["output_character_count"] = output.count
    properties["process_running"] = process?.isRunning ?? false
    properties["app_active"] = NSApp.isActive
    properties["page_url"] = webView?.url?.absoluteString
    properties["webview_loading"] = webView?.isLoading ?? false
    properties["system_uptime_seconds"] = ProcessInfo.processInfo.systemUptime
    properties["login_shell"] = LoginShellRunner.userLoginShell.lastPathComponent
    properties["failure_category"] = category.rawValue
    properties["will_try_fallback"] =
      !isFallback && UserDefaults.standard.string(forKey: versionKey) != nil
    AgentPlaybackDiagnostics.record(message: message, output: output, properties: properties)
    properties["error_message"] = message
    properties["process_output"] = output
    if launchStartedAt != nil {
      properties["outcome"] = "failure"
      AnalyticsService.shared.capture("agentplayback_launch_completed", properties)
      launchStartedAt = nil
    } else {
      AnalyticsService.shared.capture("agentplayback_runtime_failed", properties)
    }
    if !isFallback, let saved = UserDefaults.standard.string(forKey: versionKey) {
      fallbackFromAttempt = attempt.uuidString
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
    fail(
      String(localized: "Couldn’t load AgentPlayback: \(error.localizedDescription)"),
      category: .navigation,
      diagnostics: errorProperties(error))
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    guard webView === self.webView else { return }
    fail(
      String(localized: "AgentPlayback navigation failed: \(error.localizedDescription)"),
      category: .navigation,
      diagnostics: errorProperties(error))
  }

  private func errorProperties(_ error: Error) -> [String: Any] {
    let error = error as NSError
    return [
      "error_domain": error.domain,
      "error_code": error.code,
      "error_details": String(reflecting: error),
      "error_user_info": String(describing: error.userInfo),
    ]
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    fail(
      String(localized: "AgentPlayback’s window stopped responding. Try again."),
      category: .webContentTerminated)
  }

  private var launchProperties: [String: Any] {
    var properties: [String: Any] = ["mode": isFallback ? "cached_fallback" : "latest"]
    properties["attempt_id"] = attempt.uuidString
    properties["requested_version"] = requestedVersion
    properties["attempt_elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - attemptStartedAt
    if let fallbackFromAttempt { properties["fallback_from_attempt_id"] = fallbackFromAttempt }
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
