//
//  ChatView.swift
//  Dayflow
//

import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().opacity(0.3)
            messageList
            chatInputBar
        }
        .frame(maxWidth: 720, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.onAppear() }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Button(action: viewModel.navigatePrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.6, green: 0.4, blue: 0.3))
            }
            .buttonStyle(.plain)

            Text(viewModel.displayDateString)
                .font(.custom("InstrumentSerif-Regular", size: 28))
                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))

            Button(action: viewModel.navigateNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(viewModel.canNavigateForward
                        ? Color(red: 0.6, green: 0.4, blue: 0.3)
                        : Color(red: 0.6, green: 0.4, blue: 0.3).opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canNavigateForward)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        if message.role != .system {
                            ChatBubbleView(message: message, onRetry: {
                                viewModel.retryLastMessage()
                            })
                            .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onChange(of: viewModel.messages.count) {
                if let lastId = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var chatInputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your day...", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.custom("Nunito-Regular", size: 15))
                .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(red: 0.85, green: 0.78, blue: 0.70), lineWidth: 1)
                        )
                )
                .onSubmit { viewModel.sendMessage() }
                .disabled(viewModel.isLoading)

            Button(action: viewModel.sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(
                        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading
                            ? Color(hex: "F96E00").opacity(0.35)
                            : Color(hex: "F96E00")
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.8))
                .overlay(alignment: .top) {
                    Divider().opacity(0.3)
                }
        )
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    let message: ChatMessage
    var onRetry: (() -> Void)?

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if message.isLoading {
                    TypingIndicator()
                } else {
                    messageContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.content.starts(with: "Something went wrong:") {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.content)
                    .font(.custom("Nunito-Regular", size: 14))
                    .foregroundColor(Color(red: 0.7, green: 0.2, blue: 0.15))

                if let onRetry {
                    Button("Try again", action: onRetry)
                        .font(.custom("Nunito-SemiBold", size: 13))
                        .foregroundColor(Color(hex: "F96E00"))
                }
            }
        } else {
            Text(markdownContent)
                .font(.custom("Nunito-Regular", size: 14))
                .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10))
                .textSelection(.enabled)
        }
    }

    private var markdownContent: AttributedString {
        (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content)
    }

    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            return Color(red: 0.97, green: 0.93, blue: 0.88)
        } else {
            return Color(red: 0.98, green: 0.97, blue: 0.96)
        }
    }
}

// MARK: - Typing Indicator

private struct TypingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color(hex: "F96E00").opacity(0.6))
                    .frame(width: 7, height: 7)
                    .offset(y: sin(phase + Double(index) * 0.8) * 3)
            }
        }
        .frame(height: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
