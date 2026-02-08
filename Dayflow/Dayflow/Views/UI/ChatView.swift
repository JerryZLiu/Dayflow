//
//  ChatView.swift
//  Dayflow
//
//  Chat interface for asking questions about activity data.
//

import SwiftUI
import Charts
import AppKit

private let chatViewDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

struct ChatView: View {
    @ObservedObject private var chatService = ChatService.shared
    @State private var inputText = ""
    @State private var showWorkDetails = false
    @FocusState private var isInputFocused: Bool
    @Namespace private var bottomID
    @AppStorage("chatCLIPreferredTool") private var selectedTool: String = "codex"
    @AppStorage("hasChatBetaAccepted") private var hasBetaAccepted: Bool = false
    @State private var cliDetected = false
    @State private var cliDetectionTask: Task<Void, Never>?
    @State private var didCheckCLI = false
    @State private var showToolSwitchConfirm = false
    @State private var pendingToolSelection: String?
    @State private var conversationId: UUID?

    private var isUnlocked: Bool {
        hasBetaAccepted
    }

    private var cliEnabled: Bool {
        hasBetaAccepted || cliDetected
    }

    var body: some View {
        ZStack {
            if isUnlocked {
                HStack(spacing: 0) {
                    chatContent
                    if chatService.showDebugPanel {
                        debugPanel
                    }
                }
                .transition(.opacity)
            } else {
                betaLockScreen
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .preferredColorScheme(.light)
        .task {
            guard !didCheckCLI else { return }
            didCheckCLI = true
            guard !hasBetaAccepted else { return }
            await detectCLIInstallation()
        }
        .onDisappear {
            cliDetectionTask?.cancel()
            cliDetectionTask = nil
        }
        .alert("Switch model?", isPresented: $showToolSwitchConfirm) {
            Button("Switch and Reset", role: .destructive) {
                confirmToolSwitch()
            }
            Button("Cancel", role: .cancel) {
                pendingToolSelection = nil
            }
        } message: {
            Text("Switching to \(pendingToolLabel) will clear this chat's context.")
        }
    }

    private var chatContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header buttons
            HStack(spacing: 8) {
                Spacer()

                // Clear chat button (only show if there are messages)
                if !chatService.messages.isEmpty {
                    Button(action: { resetConversation() }) {
                        Text("Clear")
                            .font(.custom("Nunito", size: 12).weight(.semibold))
                            .foregroundColor(Color(hex: "F96E00"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(hex: "FFF4E9"))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(hex: "F96E00").opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Clear chat")
                }

                // Debug toggle
                Button(action: { chatService.showDebugPanel.toggle() }) {
                    Image(systemName: chatService.showDebugPanel ? "ladybug.fill" : "ladybug")
                        .font(.system(size: 14))
                        .foregroundColor(chatService.showDebugPanel ? Color(hex: "F96E00") : Color(hex: "999999"))
                }
                .buttonStyle(.plain)
                .help("Toggle debug panel")
            }
            .padding(.trailing, 12)
            .padding(.top, 8)

            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Welcome message if empty
                        if chatService.messages.isEmpty {
                            welcomeView
                        }

                        // Messages
                        ForEach(Array(chatService.messages.enumerated()), id: \.element.id) { index, message in
                            if let status = chatService.workStatus,
                               let insertionIndex = statusInsertionIndex,
                               index == insertionIndex {
                                WorkStatusCard(status: status, showDetails: $showWorkDetails)
                            }
                            MessageBubble(message: message)
                        }
                        if let status = chatService.workStatus,
                           let insertionIndex = statusInsertionIndex,
                           insertionIndex == chatService.messages.count {
                            WorkStatusCard(status: status, showDetails: $showWorkDetails)
                        }

                        // Follow-up suggestions (show after last assistant message when not processing)
                        if !chatService.isProcessing && !chatService.currentSuggestions.isEmpty {
                            followUpSuggestions
                        }

                        // Anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .onChange(of: chatService.messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: chatService.isProcessing) {
                    if chatService.isProcessing {
                        showWorkDetails = false
                    }
                    // Auto-scroll when processing starts
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }

            Divider()
                .background(Color(hex: "ECECEC"))

            // Input area
            inputArea
        }
        .background(Color(hex: "FFFAF5"))
    }

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Debug Log")
                    .font(.custom("Nunito", size: 12).weight(.bold))
                    .foregroundColor(Color(hex: "666666"))

                Spacer()

                Button(action: { copyDebugLog() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "999999"))
                }
                .buttonStyle(.plain)
                .help("Copy all")

                Button(action: { chatService.clearDebugLog() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "999999"))
                }
                .buttonStyle(.plain)
                .help("Clear log")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "F5F5F5"))

            Divider()

            // Log entries
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chatService.debugLog) { entry in
                        DebugLogEntry(entry: entry)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 350)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color(hex: "E0E0E0"))
                .frame(width: 1),
            alignment: .leading
        )
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 36))
                .foregroundColor(Color(hex: "F96E00").opacity(0.6))

            Text("Ask about your day")
                .font(.custom("InstrumentSerif-Regular", size: 24))
                .foregroundColor(Color(hex: "333333"))

            Text("Try questions like:")
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(Color(hex: "666666"))

            VStack(alignment: .leading, spacing: 10) {
                SuggestionChip(text: "Generate standup notes for yesterday") {
                    sendMessage("Generate standup notes for yesterday")
                }
                SuggestionChip(text: "What did I get done last week?") {
                    sendMessage("What did I get done last week?")
                }
                SuggestionChip(text: "What distracted me the most this past week?") {
                    sendMessage("What distracted me the most this past week?")
                }
                SuggestionChip(text: "Pull my data from the last week and tell me something interesting") {
                    sendMessage("Pull my data from the last week and tell me something interesting")
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: - Beta Lock Screen

    private var betaLockScreen: some View {
        VStack(spacing: 16) {
            Spacer()

            // Header: "Unlock Beta" with BETA badge
            HStack(alignment: .top, spacing: 4) {
                Text("Unlock Beta")
                    .font(.custom("InstrumentSerif-Italic", size: 38))
                    .foregroundColor(Color(hex: "593D2A"))

                Text("BETA")
                    .font(.custom("Nunito-Bold", size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: "F98D3D"))
                    )
                    .rotationEffect(.degrees(-12))
                    .offset(x: -4, y: -4)
            }

            // Feature description (below title)
            VStack(spacing: 6) {
                Text("We're beta testing an early version of Dashboard. It's a chat feature that intelligently pulls from your Dayflow data to generate insights. You can ask it to generate charts and other visualizations of your data.")
                    .font(.custom("Nunito-Regular", size: 14))
                    .foregroundColor(Color(hex: "593D2A").opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)

                Text("Please send feedback if you see any bugs or weird behavior!")
                    .font(.custom("Nunito-SemiBold", size: 14))
                    .foregroundColor(Color(hex: "593D2A"))
                    .multilineTextAlignment(.center)
            }

            // Main content card
            VStack(spacing: 16) {
                // CLI requirement section
                VStack(spacing: 12) {
                    Image(systemName: cliDetected ? "checkmark.circle.fill" : "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(cliDetected ? Color(hex: "34C759") : Color(hex: "F98D3D"))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeOut(duration: 0.2), value: cliDetected)

                    if cliDetected {
                        Text("Claude or Codex CLI detected")
                            .font(.custom("Nunito-SemiBold", size: 15))
                            .foregroundColor(Color(hex: "34C759"))
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else {
                        Text("Claude or Codex CLI required")
                            .font(.custom("Nunito-SemiBold", size: 15))
                            .foregroundColor(Color(hex: "593D2A"))

                        Text("It's currently only available to users using Claude or Codex CLI to power Dayflow.")
                            .font(.custom("Nunito-Regular", size: 13))
                            .foregroundColor(Color(hex: "593D2A").opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: cliDetected)

                // Continue button
                Button(action: {
                    withAnimation(.easeOut(duration: 0.25)) {
                        hasBetaAccepted = true
                    }
                }) {
                    Text(cliDetected ? "Unlock Beta" : "Install CLI to continue")
                        .font(.custom("Nunito-SemiBold", size: 15))
                        .foregroundColor(cliDetected ? Color(hex: "593D2A") : Color(hex: "999999"))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    cliDetected
                                        ? LinearGradient(
                                            colors: [
                                                Color(hex: "FFF4E9"),
                                                Color(hex: "FFE8D4")
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                        : LinearGradient(
                                            colors: [
                                                Color(hex: "F0F0F0"),
                                                Color(hex: "E8E8E8")
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            cliDetected ? Color(hex: "E8C9A8") : Color(hex: "D0D0D0"),
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(BetaButtonStyle(isEnabled: cliDetected))
                .disabled(!cliDetected)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 8)
            )
            .frame(maxWidth: 420)

            // Privacy Note (at bottom)
            VStack(spacing: 4) {
                Text("Privacy Note")
                    .font(.custom("Nunito-SemiBold", size: 12))
                    .foregroundColor(Color(hex: "593D2A").opacity(0.6))

                Text("During the beta, your questions are logged to help improve the product. Responses are not logged, so your privacy is maintained.")
                    .font(.custom("Nunito-Regular", size: 12))
                    .foregroundColor(Color(hex: "593D2A").opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "FFFAF5"))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            // Text input
            TextField(
                "",
                text: $inputText,
                prompt: Text("Ask about your day...")
                    .font(.custom("Nunito", size: 13).weight(.medium))
                    .foregroundColor(Color(hex: "AAAAAA"))
            )
            .textFieldStyle(.plain)
            .font(.custom("Nunito", size: 13).weight(.medium))
            .foregroundColor(Color(hex: "333333"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 36)
            .focused($isInputFocused)
            .disabled(chatService.isProcessing)
            .onSubmit {
                sendMessage(inputText)
            }

            // Bottom toolbar
            HStack(spacing: 8) {
                // Provider toggle
                providerToggle

                Spacer()

                // Send button
                Button(action: { sendMessage(inputText) }) {
                    ZStack {
                        if chatService.isProcessing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(Color.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(
                        inputText.isEmpty || chatService.isProcessing
                            ? Color(hex: "CCCCCC")
                            : Color(hex: "F96E00")
                    )
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || chatService.isProcessing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 44)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isInputFocused ? Color(hex: "F96E00").opacity(0.5) : Color(hex: "E0E0E0"),
                    lineWidth: 1
                )
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var providerToggle: some View {
        HStack(spacing: 6) {
            ProviderTogglePill(
                title: "Codex",
                isSelected: selectedTool == "codex",
                isEnabled: cliEnabled
            ) {
                handleToolSelection("codex")
            }
            ProviderTogglePill(
                title: "Claude",
                isSelected: selectedTool == "claude",
                isEnabled: cliEnabled
            ) {
                handleToolSelection("claude")
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(hex: "E6E6E6"), lineWidth: 1)
        )
        .opacity(cliEnabled ? 1.0 : 0.6)
        .help(cliEnabled ? "Choose CLI provider" : "Install Codex or Claude CLI to enable")
        .allowsHitTesting(cliEnabled)
    }

    private var statusInsertionIndex: Int? {
        guard chatService.workStatus != nil else { return nil }
        // Always show at the end (after the latest user message)
        return chatService.messages.count
    }

    // MARK: - Follow-up Suggestions

    private var followUpSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow up")
                .font(.custom("Nunito", size: 11).weight(.semibold))
                .foregroundColor(Color(hex: "999999"))

            FlowLayout(spacing: 8) {
                ForEach(chatService.currentSuggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) {
                        inputText = suggestion
                        isInputFocused = true
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let messageText = text
        inputText = ""

        // Track conversation for analytics
        let isNewConversation = conversationId == nil || chatService.messages.isEmpty
        if isNewConversation {
            conversationId = UUID()
        }

        // Count only user messages for index
        let messageIndex = chatService.messages.filter { $0.role == .user }.count

        // Log question to PostHog (beta analytics)
        AnalyticsService.shared.capture("chat_question_asked", [
            "question": messageText,
            "conversation_id": conversationId?.uuidString ?? "unknown",
            "is_new_conversation": isNewConversation,
            "message_index": messageIndex,
            "provider": selectedTool
        ])

        Task {
            await chatService.sendMessage(messageText)
        }
    }

    private func resetConversation() {
        chatService.clearConversation()
        conversationId = nil
    }

    private func copyDebugLog() {
        let text = chatService.debugLog.map { entry in
            "[\(chatViewDebugTimestampFormatter.string(from: entry.timestamp))] \(entry.type.rawValue)\n\(entry.content)"
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func detectCLIInstallation() async {
        cliDetectionTask?.cancel()
        cliDetectionTask = Task { @MainActor in
            let installed = await Task.detached(priority: .utility) {
                CLIDetector.isInstalled(.codex) || CLIDetector.isInstalled(.claude)
            }.value

            guard !Task.isCancelled else { return }
            cliDetected = installed
        }
    }

    private func handleToolSelection(_ tool: String) {
        guard tool != selectedTool else { return }
        guard !chatService.isProcessing else { return }

        if chatService.messages.isEmpty {
            resetConversation()
            selectedTool = tool
            return
        }

        pendingToolSelection = tool
        showToolSwitchConfirm = true
    }

    private func confirmToolSwitch() {
        guard let pendingToolSelection else { return }
        resetConversation()
        selectedTool = pendingToolSelection
        self.pendingToolSelection = nil
    }

    private var pendingToolLabel: String {
        switch pendingToolSelection {
        case "claude":
            return "Claude"
        default:
            return "Codex"
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .toolCall:
            ToolCallBubble(message: message)
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.content)
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "F98D3D"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var assistantBubble: some View {
        let blocks = ChatContentParser.blocks(from: message.content)
        return HStack {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    switch block {
                    case .text(_, let content):
                        renderMarkdownLines(content)
                    case .chart(let spec):
                        ChatChartBlockView(spec: spec)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: "E8E8E8"), lineWidth: 1)
            )
            .environment(\.openURL, OpenURLAction { url in
                handleAssistantLinkTap(url)
            })
            Spacer(minLength: 60)
        }
    }

    private func renderMarkdownLines(_ content: String) -> some View {
        // Convert markdown bullets to bullet characters for display
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n- ", with: "\n• ")

        let processed = normalized.hasPrefix("- ")
            ? "• " + String(normalized.dropFirst(2))
            : normalized

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        let displayText: Text
        if let parsed = try? AttributedString(markdown: processed, options: options) {
            displayText = Text(parsed)
        } else {
            displayText = Text(processed)
        }

        return displayText
            .font(.custom("Nunito", size: 13).weight(.medium))
            .foregroundColor(Color(hex: "333333"))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func handleAssistantLinkTap(_ url: URL) -> OpenURLAction.Result {
        guard let externalURL = normalizedExternalURL(from: url) else {
            print("[ChatView] Blocked unsupported URL: \(url.absoluteString)")
            return .discarded
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(externalURL, configuration: configuration) { _, error in
            if let error {
                print("[ChatView] Failed opening URL \(externalURL.absoluteString): \(error.localizedDescription)")
            }
        }
        return .handled
    }

    private func normalizedExternalURL(from rawURL: URL) -> URL? {
        if let scheme = rawURL.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto":
                return rawURL
            default:
                return nil
            }
        }

        let trimmed = rawURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prefixed = trimmed.hasPrefix("//")
            ? "https:\(trimmed)"
            : "https://\(trimmed)"

        guard let normalized = URL(string: prefixed),
              let scheme = normalized.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = normalized.host,
              !host.isEmpty else {
            return nil
        }

        return normalized
    }
}

// MARK: - Inline Charts

private enum ChatContentBlock: Identifiable {
    case text(id: UUID, content: String)
    case chart(ChatChartSpec)

    var id: UUID {
        switch self {
        case .text(let id, _):
            return id
        case .chart(let spec):
            return spec.id
        }
    }
}

private enum ChatChartSpec: Identifiable {
    case bar(BasicChartSpec)
    case line(BasicChartSpec)
    case stackedBar(StackedBarChartSpec)
    case donut(DonutChartSpec)
    case heatmap(HeatmapChartSpec)
    case gantt(GanttChartSpec)

    var id: UUID {
        switch self {
        case .bar(let spec):
            return spec.id
        case .line(let spec):
            return spec.id
        case .stackedBar(let spec):
            return spec.id
        case .donut(let spec):
            return spec.id
        case .heatmap(let spec):
            return spec.id
        case .gantt(let spec):
            return spec.id
        }
    }

    var title: String {
        switch self {
        case .bar(let spec):
            return spec.title
        case .line(let spec):
            return spec.title
        case .stackedBar(let spec):
            return spec.title
        case .donut(let spec):
            return spec.title
        case .heatmap(let spec):
            return spec.title
        case .gantt(let spec):
            return spec.title
        }
    }

    static func parse(type: String, jsonString: String) -> ChatChartSpec? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        switch type {
        case "bar":
            guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
            return .bar(BasicChartSpec(
                title: payload.title,
                labels: payload.x,
                values: payload.y,
                colorHex: sanitizeHex(payload.color)
            ))
        case "line":
            guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
            return .line(BasicChartSpec(
                title: payload.title,
                labels: payload.x,
                values: payload.y,
                colorHex: sanitizeHex(payload.color)
            ))
        case "stacked_bar":
            guard let payload = try? JSONDecoder().decode(StackedPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, !payload.series.isEmpty else { return nil }

            let series = payload.series.compactMap { entry -> StackedBarChartSpec.Series? in
                guard !entry.values.isEmpty, entry.values.count == payload.x.count else { return nil }
                return StackedBarChartSpec.Series(
                    name: entry.name,
                    values: entry.values,
                    colorHex: sanitizeHex(entry.color)
                )
            }
            guard !series.isEmpty else { return nil }

            return .stackedBar(StackedBarChartSpec(
                title: payload.title,
                categories: payload.x,
                series: series
            ))
        case "donut":
            guard let payload = try? JSONDecoder().decode(DonutPayload.self, from: data) else { return nil }
            guard !payload.labels.isEmpty, payload.labels.count == payload.values.count else { return nil }
            let colors = payload.colors?.map { sanitizeHex($0) }
            let colorHexes: [String?]
            if let colors, colors.count == payload.labels.count {
                colorHexes = colors
            } else {
                colorHexes = Array(repeating: nil, count: payload.labels.count)
            }
            return .donut(DonutChartSpec(
                title: payload.title,
                labels: payload.labels,
                values: payload.values,
                colorHexes: colorHexes
            ))
        case "heatmap":
            guard let payload = try? JSONDecoder().decode(HeatmapPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, !payload.y.isEmpty else { return nil }
            guard payload.values.count == payload.y.count else { return nil }
            for row in payload.values {
                guard row.count == payload.x.count else { return nil }
            }
            return .heatmap(HeatmapChartSpec(
                title: payload.title,
                xLabels: payload.x,
                yLabels: payload.y,
                values: payload.values,
                colorHex: sanitizeHex(payload.color)
            ))
        case "gantt":
            guard let payload = try? JSONDecoder().decode(GanttPayload.self, from: data) else { return nil }
            let items = payload.items.compactMap { item -> GanttChartSpec.Item? in
                guard item.end > item.start else { return nil }
                return GanttChartSpec.Item(
                    label: item.label,
                    start: item.start,
                    end: item.end,
                    colorHex: sanitizeHex(item.color)
                )
            }
            guard !items.isEmpty else { return nil }
            return .gantt(GanttChartSpec(
                title: payload.title,
                items: items
            ))
        default:
            return nil
        }
    }

    private struct BasicPayload: Decodable {
        let title: String
        let x: [String]
        let y: [Double]
        let color: String?
    }

    private struct StackedPayload: Decodable {
        let title: String
        let x: [String]
        let series: [SeriesPayload]

        struct SeriesPayload: Decodable {
            let name: String
            let values: [Double]
            let color: String?
        }
    }

    private struct DonutPayload: Decodable {
        let title: String
        let labels: [String]
        let values: [Double]
        let colors: [String]?
    }

    private struct HeatmapPayload: Decodable {
        let title: String
        let x: [String]
        let y: [String]
        let values: [[Double]]
        let color: String?
    }

    private struct GanttPayload: Decodable {
        let title: String
        let items: [ItemPayload]

        struct ItemPayload: Decodable {
            let label: String
            let start: Double
            let end: Double
            let color: String?
        }
    }

    private static func sanitizeHex(_ value: String?) -> String? {
        guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        let length = raw.count
        guard length == 6 || length == 8 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw.uppercased()
    }
}

private struct BasicChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let labels: [String]
    let values: [Double]
    let colorHex: String?
}

private struct StackedBarChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let categories: [String]
    let series: [Series]

    struct Series: Identifiable {
        let id = UUID()
        let name: String
        let values: [Double]
        let colorHex: String?
    }
}

private struct DonutChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let labels: [String]
    let values: [Double]
    let colorHexes: [String?]
}

private struct HeatmapChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let xLabels: [String]
    let yLabels: [String]
    let values: [[Double]]
    let colorHex: String?
}

private struct GanttChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let items: [Item]

    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let start: Double
        let end: Double
        let colorHex: String?
    }
}

private struct ChatContentParser {
    static func blocks(from text: String) -> [ChatContentBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let pattern = "```chart\\s+type\\s*=\\s*(\\w+)\\s*\\n([\\s\\S]*?)\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(id: UUID(), content: text)]
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = regex.matches(in: normalized, range: range)
        guard !matches.isEmpty else { return [.text(id: UUID(), content: text)] }

        var blocks: [ChatContentBlock] = []
        var currentIndex = normalized.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: normalized) else { continue }

            if matchRange.lowerBound > currentIndex {
                let chunk = String(normalized[currentIndex..<matchRange.lowerBound])
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(id: UUID(), content: chunk))
                }
            }

            if let typeRange = Range(match.range(at: 1), in: normalized),
               let jsonRange = Range(match.range(at: 2), in: normalized) {
                let typeString = normalized[typeRange].lowercased()
                let jsonString = normalized[jsonRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if let spec = ChatChartSpec.parse(type: typeString, jsonString: jsonString) {
                    blocks.append(.chart(spec))
                } else {
                    blocks.append(.text(id: UUID(), content: String(normalized[matchRange])))
                }
            }

            currentIndex = matchRange.upperBound
        }

        if currentIndex < normalized.endIndex {
            let tail = String(normalized[currentIndex...])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(id: UUID(), content: tail))
            }
        }

        return blocks.isEmpty ? [.text(id: UUID(), content: text)] : blocks
    }
}

private struct ChatChartBlockView: View {
    let spec: ChatChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                Text(title)
                    .font(.custom("Nunito", size: 12).weight(.semibold))
                    .foregroundColor(Color(hex: "4A4A4A"))
            }
            chartBody
                .frame(height: 180)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch spec {
        case .bar(let chartSpec):
            basicChartBody(spec: chartSpec, isLine: false)
        case .line(let chartSpec):
            basicChartBody(spec: chartSpec, isLine: true)
        case .stackedBar(let chartSpec):
            stackedBarBody(spec: chartSpec)
        case .donut(let chartSpec):
            donutBody(spec: chartSpec)
        case .heatmap(let chartSpec):
            heatmapBody(spec: chartSpec)
        case .gantt(let chartSpec):
            ganttBody(spec: chartSpec)
        }
    }

    private func basicChartBody(spec: BasicChartSpec, isLine: Bool) -> some View {
        let points = Array(zip(spec.labels, spec.values)).map { ChartPoint(label: $0.0, value: $0.1) }
        let color = seriesColor(for: spec.colorHex, fallbackIndex: 0)

        return Chart(points) { point in
            if isLine {
                LineMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)

                PointMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
            } else {
                BarMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.label)) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func stackedBarBody(spec: StackedBarChartSpec) -> some View {
        let points = stackedPoints(from: spec)
        let domain = spec.series.map(\.name)
        let range = spec.series.enumerated().map { index, series in
            seriesColor(for: series.colorHex, fallbackIndex: index)
        }

        return Chart(points) { point in
            BarMark(
                x: .value("Category", point.category),
                y: .value("Value", point.value)
            )
            .foregroundStyle(by: .value("Series", point.seriesName))
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartXAxis {
            AxisMarks(values: spec.categories) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func donutBody(spec: DonutChartSpec) -> some View {
        let slices = zip(spec.labels, spec.values).map { DonutSlice(label: $0.0, value: $0.1) }
        let range = spec.labels.enumerated().map { index, _ in
            let hex = spec.colorHexes.indices.contains(index) ? spec.colorHexes[index] : nil
            return seriesColor(for: hex, fallbackIndex: index)
        }

        return Chart(slices) { slice in
            SectorMark(
                angle: .value("Value", slice.value),
                innerRadius: .ratio(0.6),
                angularInset: 1
            )
            .foregroundStyle(by: .value("Label", slice.label))
        }
        .chartForegroundStyleScale(domain: spec.labels, range: range)
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private func heatmapBody(spec: HeatmapChartSpec) -> some View {
        let points = heatmapPoints(from: spec)
        let range = heatmapRange(for: spec)
        let baseColor = seriesColor(for: spec.colorHex, fallbackIndex: 1)

        return Chart(points) { point in
            RectangleMark(
                x: .value("X", point.xLabel),
                y: .value("Y", point.yLabel),
                width: .ratio(0.9),
                height: .ratio(0.9)
            )
            .foregroundStyle(heatmapColor(value: point.value, range: range, base: baseColor))
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: spec.xLabels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: spec.yLabels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func ganttBody(spec: GanttChartSpec) -> some View {
        let domain = ganttDomain(for: spec)
        let labels = spec.items.map(\.label)

        return Chart(spec.items) { item in
            BarMark(
                xStart: .value("Start", item.start),
                xEnd: .value("End", item.end),
                y: .value("Label", item.label)
            )
            .foregroundStyle(seriesColor(for: item.colorHex, fallbackIndex: itemIndex(for: item, in: spec)))
            .cornerRadius(4)
        }
        .chartXScale(domain: domain.min...domain.max)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                if let number = value.as(Double.self) {
                    AxisValueLabel {
                        Text(number, format: .number.precision(.fractionLength(1)))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: labels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func stackedPoints(from spec: StackedBarChartSpec) -> [StackedPoint] {
        var points: [StackedPoint] = []
        for series in spec.series {
            for (index, category) in spec.categories.enumerated() {
                points.append(StackedPoint(
                    category: category,
                    seriesName: series.name,
                    value: series.values[index]
                ))
            }
        }
        return points
    }

    private func seriesColor(for hex: String?, fallbackIndex: Int) -> Color {
        if let hex {
            return Color(hex: hex)
        }
        return Self.defaultPalette[fallbackIndex % Self.defaultPalette.count]
    }

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    private struct StackedPoint: Identifiable {
        let id = UUID()
        let category: String
        let seriesName: String
        let value: Double
    }

    private struct DonutSlice: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    private struct HeatmapPoint: Identifiable {
        let id = UUID()
        let xLabel: String
        let yLabel: String
        let value: Double
    }

    private struct HeatmapRange {
        let min: Double
        let max: Double
    }

    private struct GanttDomain {
        let min: Double
        let max: Double
    }

    private func heatmapPoints(from spec: HeatmapChartSpec) -> [HeatmapPoint] {
        var points: [HeatmapPoint] = []
        for (rowIndex, row) in spec.values.enumerated() {
            let yLabel = spec.yLabels[rowIndex]
            for (colIndex, value) in row.enumerated() {
                points.append(HeatmapPoint(
                    xLabel: spec.xLabels[colIndex],
                    yLabel: yLabel,
                    value: value
                ))
            }
        }
        return points
    }

    private func heatmapRange(for spec: HeatmapChartSpec) -> HeatmapRange {
        let flattened = spec.values.flatMap { $0 }
        let minValue = flattened.min() ?? 0
        let maxValue = flattened.max() ?? minValue
        return HeatmapRange(min: minValue, max: maxValue)
    }

    private func heatmapColor(value: Double, range: HeatmapRange, base: Color) -> Color {
        let denominator = range.max - range.min
        let normalized = denominator == 0 ? 1.0 : (value - range.min) / denominator
        let clamped = min(max(normalized, 0), 1)
        let opacity = 0.2 + (0.8 * clamped)
        return base.opacity(opacity)
    }

    private func ganttDomain(for spec: GanttChartSpec) -> GanttDomain {
        let starts = spec.items.map(\.start)
        let ends = spec.items.map(\.end)
        let minValue = min(starts.min() ?? 0, ends.min() ?? 0)
        let maxValue = max(starts.max() ?? 0, ends.max() ?? 0)
        return GanttDomain(min: minValue, max: maxValue)
    }

    private func itemIndex(for item: GanttChartSpec.Item, in spec: GanttChartSpec) -> Int {
        spec.items.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    private static let defaultPalette: [Color] = [
        Color(hex: "F96E00"),
        Color(hex: "1F6FEB"),
        Color(hex: "2E7D32"),
        Color(hex: "8E24AA"),
        Color(hex: "00897B")
    ]
}

// MARK: - Work Status Card

private struct WorkStatusCard: View {
    let status: ChatWorkStatus
    @Binding var showDetails: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                header

                if status.stage == .error, let message = status.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.custom("Nunito", size: 12).weight(.semibold))
                        .foregroundColor(Color(hex: "C62828"))
                }

                if !status.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(status.tools) { tool in
                            ToolStatusRow(tool: tool, showDetails: showDetails)
                        }
                    }
                }

                if status.hasDetails {
                    Button(action: { showDetails.toggle() }) {
                        HStack(spacing: 4) {
                            Text(showDetails ? "Hide details" : "Show details")
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.custom("Nunito", size: 11).weight(.semibold))
                        .foregroundColor(Color(hex: "8B5E3C"))
                    }
                    .buttonStyle(.plain)
                }

                if showDetails, !status.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(status.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "666666"))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(hex: "FFFFFF").opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )

            Spacer(minLength: 60)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 14, height: 14, alignment: .center)

            HStack(spacing: 0) {
                Text(headerTitle)
                if showsEllipsis {
                    AnimatedEllipsis()
                }
            }
            .font(.custom("Nunito", size: 12).weight(.semibold))
            .foregroundColor(Color(hex: "4A4A4A"))

            Spacer()
        }
    }

    private var headerTitle: String {
        switch status.stage {
        case .thinking:
            return "Thinking"
        case .runningTools:
            return "Running tools"
        case .answering:
            return "Answering"
        case .error:
            return "Something went wrong"
        }
    }

    private var showsEllipsis: Bool {
        switch status.stage {
        case .thinking, .runningTools, .answering:
            return true
        case .error:
            return false
        }
    }

    private var headerIcon: String {
        switch status.stage {
        case .thinking:
            return "sparkles"
        case .runningTools:
            return "wrench.and.screwdriver"
        case .answering:
            return "text.bubble"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch status.stage {
        case .error:
            return Color(hex: "C62828")
        default:
            return Color(hex: "F96E00")
        }
    }

    private var backgroundColor: Color {
        switch status.stage {
        case .error:
            return Color(hex: "FFEBEE")
        default:
            return Color(hex: "FFF4E9")
        }
    }

    private var borderColor: Color {
        switch status.stage {
        case .error:
            return Color(hex: "FFCDD2")
        default:
            return Color(hex: "F96E00").opacity(0.2)
        }
    }
}

private struct AnimatedEllipsis: View {
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / interval) % 3 + 1
            Text(String(repeating: ".", count: step))
                .accessibilityHidden(true)
        }
    }
}

private struct ToolStatusRow: View {
    let tool: ChatWorkStatus.ToolRun
    let showDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIcon
                    .frame(width: 14, height: 14, alignment: .center)
                Text(tool.summary)
                    .font(.custom("Nunito", size: 12).weight(.semibold))
                    .foregroundColor(textColor)
            }

            if showDetails {
                Text(tool.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "666666"))
                    .textSelection(.enabled)
                    .lineLimit(3)

                if !trimmedOutput.isEmpty {
                    Text(trimmedOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "555555"))
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(6)
                        .background(Color(hex: "FFFFFF").opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private var trimmedOutput: String {
        tool.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.state {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .tint(Color(hex: "F96E00"))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "34C759"))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "C62828"))
        }
    }

    private var textColor: Color {
        switch tool.state {
        case .failed:
            return Color(hex: "C62828")
        default:
            return Color(hex: "4A4A4A")
        }
    }
}

// MARK: - Suggestion Chip

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom("Nunito", size: 12).weight(.medium))
                .foregroundColor(Color(hex: "F96E00"))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: "FFF4E9"))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(hex: "F96E00").opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Beta Button Style (hover + press animations)

private struct BetaButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ProviderTogglePill: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    private var backgroundColor: Color {
        if !isEnabled { return Color(hex: "F2F2F2") }
        return isSelected ? Color(hex: "FFF4E9") : Color.white
    }

    private var borderColor: Color {
        if !isEnabled { return Color(hex: "E0E0E0") }
        return isSelected ? Color(hex: "F96E00").opacity(0.25) : Color(hex: "E0E0E0")
    }

    private var textColor: Color {
        if !isEnabled { return Color(hex: "B0B0B0") }
        return isSelected ? Color(hex: "F96E00") : Color(hex: "666666")
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - Debug Log Entry

private struct DebugLogEntry: View {
    let entry: ChatDebugEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with type and timestamp
            HStack(spacing: 6) {
                Text(entry.type.rawValue)
                    .font(.custom("Nunito", size: 10).weight(.bold))
                    .foregroundColor(Color(hex: entry.typeColor))

                Spacer()

                Text(formatTimestamp(entry.timestamp))
                    .font(.custom("Nunito", size: 9))
                    .foregroundColor(Color(hex: "AAAAAA"))
            }

            // Content (scrollable if long)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(entry.content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "333333"))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
        }
        .padding(8)
        .background(Color(hex: "FAFAFA"))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(hex: entry.typeColor).opacity(0.3), lineWidth: 1)
        )
    }

    private func formatTimestamp(_ date: Date) -> String {
        chatViewDebugTimestampFormatter.string(from: date)
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Thinking Indicator

private struct ThinkingIndicator: View {
    @State private var dotScale: [CGFloat] = [1, 1, 1]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "F96E00"))

            Text("Thinking")
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color(hex: "F96E00"))
                        .frame(width: 4, height: 4)
                        .scaleEffect(dotScale[index])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(hex: "FFF4E9"), Color(hex: "FFECD8")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "F96E00").opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        // Staggered bouncing dots animation
        for i in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(Double(i) * 0.15)
            ) {
                dotScale[i] = 1.4
            }
        }
    }
}

// MARK: - Preview

#Preview("Chat View") {
    ChatView()
        .frame(width: 400, height: 600)
}

#Preview("Thinking Indicator") {
    ThinkingIndicator()
        .padding()
        .background(Color(hex: "FFFAF5"))
}
