import AppKit
import Charts
import SwiftUI

extension ChatView {
  var chatContent: some View {
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
          .pointingHandCursor()
        }

        // Debug toggle
        Button(action: { chatService.showDebugPanel.toggle() }) {
          Image(systemName: chatService.showDebugPanel ? "ladybug.fill" : "ladybug")
            .font(.system(size: 14))
            .foregroundColor(
              chatService.showDebugPanel ? Color(hex: "F96E00") : Color(hex: "999999"))
        }
        .buttonStyle(.plain)
        .help("Toggle debug panel")
        .pointingHandCursor()

        Button(
          action: {
            showMemoryPanel.toggle()
            if showMemoryPanel {
              syncMemoryFromStoreIfNeeded()
              AnalyticsService.shared.capture("chat_memory_panel_opened")
            }
          }
        ) {
          Image(systemName: showMemoryPanel ? "brain.head.profile.fill" : "brain.head.profile")
            .font(.system(size: 14))
            .foregroundColor(showMemoryPanel ? Color(hex: "F96E00") : Color(hex: "999999"))
        }
        .buttonStyle(.plain)
        .help("Toggle memory panel")
        .pointingHandCursor()
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
                index == insertionIndex
              {
                WorkStatusCard(status: status, showDetails: $showWorkDetails)
              }
              ChatMessageRow(
                message: message,
                showsAssistantFooter: shouldShowAssistantFeedbackFooter(for: message),
                selectedDirection: chatVoteSelections[message.id],
                showsThanks: thankedMessageIDs.contains(message.id),
                onCopy: { copyAssistantMessage(message) },
                onRate: { direction in handleAssistantRating(direction, for: message) }
              )
            }
            if let status = chatService.workStatus,
              let insertionIndex = statusInsertionIndex,
              insertionIndex == chatService.messages.count
            {
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
      .onChange(of: chatService.messages.isEmpty) { _, isEmpty in
        if isEmpty {
          didAnimateWelcome = false
          resetChatFeedbackState()
        }
      }

      Divider()
        .background(Color(hex: "ECECEC"))

      // Input area
      inputArea
    }
    .background(
      LinearGradient(
        colors: [Color(hex: "FFFAF5"), Color(hex: "FFF6EC")],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  // MARK: - Debug Panel

  var debugPanel: some View {
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
        .pointingHandCursor()

        Button(action: { chatService.clearDebugLog() }) {
          Image(systemName: "trash")
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "999999"))
        }
        .buttonStyle(.plain)
        .help("Clear log")
        .pointingHandCursor()
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

  // MARK: - Memory Panel

  var memoryPanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Memory")
          .font(.custom("Nunito", size: 12).weight(.bold))
          .foregroundColor(Color(hex: "666666"))
        Spacer()
        Text("\(memoryCharacterCount)/\(DashboardChatMemoryStore.maxCharacters)")
          .font(.custom("Nunito", size: 11))
          .foregroundColor(Color(hex: "999999"))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(hex: "F5F5F5"))

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Auto-updated from assistant replies. You can edit this manually.")
          .font(.custom("Nunito", size: 11))
          .foregroundColor(Color(hex: "8A8A8A"))

        TextEditor(text: $memoryDraft)
          .font(.custom("Nunito", size: 12))
          .padding(8)
          .background(Color(hex: "FFFCF8"))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color(hex: "E7DDD1"), lineWidth: 1)
          )
          .onChange(of: memoryDraft) { _, newValue in
            guard newValue.count > DashboardChatMemoryStore.maxCharacters else { return }
            memoryDraft = String(newValue.prefix(DashboardChatMemoryStore.maxCharacters))
          }

        HStack {
          Text("Last updated: \(memoryUpdatedLabel)")
            .font(.custom("Nunito", size: 10))
            .foregroundColor(Color(hex: "999999"))
          Spacer()
        }

        HStack(spacing: 8) {
          Button("Save") { saveMemoryDraft() }
            .buttonStyle(.plain)
            .font(.custom("Nunito", size: 11).weight(.bold))
            .foregroundColor(isMemoryDirty ? Color(hex: "F96E00") : Color(hex: "999999"))
            .disabled(!isMemoryDirty)
            .pointingHandCursor()

          Button("Reload") { reloadMemoryDraft() }
            .buttonStyle(.plain)
            .font(.custom("Nunito", size: 11).weight(.bold))
            .foregroundColor(isMemoryDirty ? Color(hex: "555555") : Color(hex: "AAAAAA"))
            .disabled(!isMemoryDirty)
            .pointingHandCursor()

          Spacer()

          Button("Clear") { clearMemoryDraft() }
            .buttonStyle(.plain)
            .font(.custom("Nunito", size: 11).weight(.bold))
            .foregroundColor(storedMemoryBlob.isEmpty ? Color(hex: "AAAAAA") : Color(hex: "C85A4B"))
            .disabled(storedMemoryBlob.isEmpty)
            .pointingHandCursor()
        }
      }
      .padding(12)
    }
    .frame(width: 360)
    .background(Color.white)
    .overlay(
      Rectangle()
        .fill(Color(hex: "E0E0E0"))
        .frame(width: 1),
      alignment: .leading
    )
  }

  // MARK: - Welcome View

  var welcomeView: some View {
    VStack(spacing: 0) {
      ZStack {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color.white.opacity(0.86), Color(hex: "FFF8EF").opacity(0.95)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color(hex: "F5DFC7"), lineWidth: 1)
          )
          .shadow(color: Color(hex: "E7B98E").opacity(0.24), radius: 20, x: 0, y: 10)

        VStack(spacing: 16) {
          HStack(alignment: .center, spacing: 12) {
            ZStack {
              Circle()
                .fill(
                  LinearGradient(
                    colors: [Color(hex: "FFE5CD"), Color(hex: "FFCF9D")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )
              Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color(hex: "C9670D"))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
              Text("Ask about your Dayflow data")
                .font(.custom("InstrumentSerif-Regular", size: 30))
                .foregroundColor(Color(hex: "2F2A24"))

              Text("Ask questions, analyze your timeline, and generate charts/graphs.")
                .font(.custom("Nunito", size: 13).weight(.semibold))
                .foregroundColor(Color(hex: "7D6B5B"))

              Text("I remember your response preferences, so feel free to teach me your style.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(Color(hex: "8A7765"))
            }

            Spacer(minLength: 0)
          }

          VStack(alignment: .leading, spacing: 10) {
            Text("Try one of these")
              .font(.custom("Nunito", size: 12).weight(.bold))
              .foregroundColor(Color(hex: "8A7765"))

            ForEach(Array(welcomePrompts.enumerated()), id: \.offset) { index, prompt in
              WelcomeSuggestionRow(prompt: prompt) {
                sendMessage(prompt.text)
              }
              .opacity(didAnimateWelcome ? 1 : 0)
              .offset(y: didAnimateWelcome ? 0 : 8)
              .animation(welcomeSuggestionAnimation(at: index), value: didAnimateWelcome)
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 24)
      }
      .frame(maxWidth: 760)
      .opacity(didAnimateWelcome ? 1 : 0)
      .scaleEffect(reduceMotion ? 1 : (didAnimateWelcome ? 1 : 0.985))
      .blur(radius: reduceMotion || didAnimateWelcome ? 0 : 6)
      .onAppear {
        guard !didAnimateWelcome else { return }
        withAnimation(welcomeHeroAnimation) {
          didAnimateWelcome = true
        }
      }

      Spacer(minLength: 8)
    }
    .frame(maxWidth: .infinity, minHeight: 420, alignment: .top)
    .padding(.bottom, 24)
  }

  // MARK: - Beta Lock Screen

  var betaLockScreen: some View {
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
        Text(
          "Chat lets you ask questions about your Dayflow activity and get summaries, comparisons, and insights."
        )
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
        // Runtime requirement section
        VStack(spacing: 12) {
          Image(
            systemName: anyRuntimeAvailable ? "checkmark.circle.fill" : "bolt.horizontal.circle"
          )
          .font(.system(size: 32))
          .foregroundColor(anyRuntimeAvailable ? Color(hex: "34C759") : Color(hex: "F98D3D"))
          .contentTransition(.symbolEffect(.replace))
          .animation(.easeOut(duration: 0.2), value: anyRuntimeAvailable)

          if anyRuntimeAvailable {
            Text("Gemini key or CLI runtime detected")
              .font(.custom("Nunito-SemiBold", size: 15))
              .foregroundColor(Color(hex: "34C759"))
              .transition(.opacity.combined(with: .scale(scale: 0.95)))
          } else {
            Text("Gemini API key or CLI required")
              .font(.custom("Nunito-SemiBold", size: 15))
              .foregroundColor(Color(hex: "593D2A"))

            Text(
              "Unlock chat by either adding a Gemini API key in Settings or installing Codex/Claude CLI."
            )
            .font(.custom("Nunito-Regular", size: 13))
            .foregroundColor(Color(hex: "593D2A").opacity(0.8))
            .multilineTextAlignment(.center)
          }
        }
        .animation(.easeOut(duration: 0.25), value: anyRuntimeAvailable)

        // Continue button
        Button(action: {
          withAnimation(.easeOut(duration: 0.25)) {
            hasBetaAccepted = true
          }
        }) {
          Text(anyRuntimeAvailable ? "Unlock Beta" : "Configure a runtime to continue")
            .font(.custom("Nunito-SemiBold", size: 15))
            .foregroundColor(anyRuntimeAvailable ? Color(hex: "593D2A") : Color(hex: "999999"))
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(
              Capsule()
                .fill(
                  anyRuntimeAvailable
                    ? LinearGradient(
                      colors: [
                        Color(hex: "FFF4E9"),
                        Color(hex: "FFE8D4"),
                      ],
                      startPoint: .top,
                      endPoint: .bottom
                    )
                    : LinearGradient(
                      colors: [
                        Color(hex: "F0F0F0"),
                        Color(hex: "E8E8E8"),
                      ],
                      startPoint: .top,
                      endPoint: .bottom
                    )
                )
                .overlay(
                  Capsule()
                    .stroke(
                      anyRuntimeAvailable ? Color(hex: "E8C9A8") : Color(hex: "D0D0D0"),
                      lineWidth: 1
                    )
                )
            )
        }
        .buttonStyle(BetaButtonStyle(isEnabled: anyRuntimeAvailable))
        .disabled(!anyRuntimeAvailable)
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

        Text(
          "During the beta, your questions are logged to help improve the product. Responses are not logged, so your privacy is maintained."
        )
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

  var inputArea: some View {
    VStack(spacing: 0) {
      // Text input
      AppKitComposerTextField(
        text: $inputText,
        isFocused: $isInputFocused,
        focusToken: composerFocusToken,
        placeholder: "Ask about your Dayflow data...",
        onSubmit: submitCurrentInputIfAllowed
      )
      .frame(height: 50, alignment: .leading)

      Rectangle()
        .fill(Color(hex: "EEE4D8"))
        .frame(height: 1)

      // Bottom toolbar
      HStack(spacing: 8) {
        // Provider toggle
        providerToggle

        Spacer()

        if chatService.isProcessing {
          HStack(spacing: 6) {
            ProgressView()
              .scaleEffect(0.55)
              .tint(Color(hex: "C18043"))
            Text("Answering")
              .font(.custom("Nunito", size: 11).weight(.bold))
              .foregroundColor(Color(hex: "9B7753"))
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(
            Capsule()
              .fill(Color(hex: "FFF3E6"))
          )
          .overlay(
            Capsule()
              .stroke(Color(hex: "F0CBA7"), lineWidth: 1)
          )
        }

        // Send button
        Button(action: { submitCurrentInputIfAllowed() }) {
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
          .frame(width: 32, height: 32)
          .background(
            canSubmitCurrentInput
              ? LinearGradient(
                colors: [Color(hex: "FAA457"), Color(hex: "F96E00")],
                startPoint: .top,
                endPoint: .bottom
              )
              : LinearGradient(
                colors: [Color(hex: "DDDDDD"), Color(hex: "CECECE")],
                startPoint: .top,
                endPoint: .bottom
              )
          )
          .clipShape(Circle())
          .overlay(
            Circle()
              .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
          )
          .shadow(
            color: canSubmitCurrentInput ? Color(hex: "D37E2D").opacity(0.35) : Color.clear,
            radius: 8,
            x: 0,
            y: 3
          )
        }
        .buttonStyle(PressScaleButtonStyle(isEnabled: canSubmitCurrentInput))
        .disabled(!canSubmitCurrentInput)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(minHeight: 48)
    }
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color.white, Color(hex: "FFF8F0")],
            startPoint: .top,
            endPoint: .bottom
          )
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(composerBorderColor, lineWidth: isInputFocused ? 1.2 : 1)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .inset(by: 0.6)
        .stroke(Color.white.opacity(0.65), lineWidth: 0.8)
    )
    .shadow(color: Color(hex: "D99A5A").opacity(0.14), radius: 14, x: 0, y: 6)
    .animation(.easeOut(duration: 0.16), value: isInputFocused)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  var providerToggle: some View {
    HStack(spacing: 6) {
      ProviderTogglePill(
        title: "Gemini",
        isSelected: selectedProvider == .gemini,
        isEnabled: isProviderAvailable(.gemini)
      ) {
        handleProviderSelection(.gemini)
      }
      ProviderTogglePill(
        title: "Codex",
        isSelected: selectedProvider == .codex,
        isEnabled: isProviderAvailable(.codex)
      ) {
        handleProviderSelection(.codex)
      }
      ProviderTogglePill(
        title: "Claude",
        isSelected: selectedProvider == .claude,
        isEnabled: isProviderAvailable(.claude)
      ) {
        handleProviderSelection(.claude)
      }
    }
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(Color.white.opacity(0.84))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(Color(hex: "E4D6C8"), lineWidth: 1)
    )
    .help(providerToggleHelpText)
  }

  var statusInsertionIndex: Int? {
    guard chatService.workStatus != nil else { return nil }
    // Always show at the end (after the latest user message)
    return chatService.messages.count
  }

  // MARK: - Follow-up Suggestions

  var followUpSuggestions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Follow up")
        .font(.custom("Nunito", size: 11).weight(.semibold))
        .foregroundColor(Color(hex: "999999"))

      ChatFlowLayout(spacing: 8) {
        ForEach(chatService.currentSuggestions, id: \.self) { suggestion in
          SuggestionChip(text: suggestion) {
            inputText = suggestion
            isInputFocused = true
            composerFocusToken += 1
          }
        }
      }
    }
    .padding(.top, 4)
  }

}
