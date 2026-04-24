import AppKit
import Foundation
import SwiftUI

enum LocalLLMTestConstants {
  static let blankImageDataURL = LocalLLMTestImageFactory.blankImageDataURL(
    width: 1280, height: 720)
  static let prompt = "What color is this image? Answer with a single word."
  static let slowMachineMessage =
    "It took longer than 30 seconds, so your machine doesn't appear powerful enough to run this model locally."
  static let maxLatency: TimeInterval = 30
}

enum LocalLLMTestImageFactory {
  static func blankImageDataURL(width: Int, height: Int) -> String {
    guard let data = makeWhiteImageData(width: width, height: height) else {
      assertionFailure("Failed to build local LLM test image")
      return ""
    }
    return "data:image/jpeg;base64,\(data.base64EncodedString())"
  }

  static func makeWhiteImageData(width: Int, height: Int) -> Data? {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return nil
    }

    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
      NSGraphicsContext.current = context
      NSColor.white.setFill()
      rect.fill()
      context.flushGraphics()
    }
    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(using: .jpeg, properties: [:])
  }
}

struct LocalLLMTestView: View {
  @Binding var baseURL: String
  @Binding var modelId: String
  @Binding var apiKey: String
  let engine: LocalEngine
  let showInputs: Bool
  let buttonLabel: String
  let basePlaceholder: String?
  let modelPlaceholder: String?
  let onTestComplete: (Bool) -> Void

  init(
    baseURL: Binding<String>,
    modelId: Binding<String>,
    apiKey: Binding<String> = .constant(""),
    engine: LocalEngine,
    showInputs: Bool = true,
    buttonLabel: String = "Test Local API",
    basePlaceholder: String? = nil,
    modelPlaceholder: String? = nil,
    onTestComplete: @escaping (Bool) -> Void
  ) {
    _baseURL = baseURL
    _modelId = modelId
    _apiKey = apiKey
    self.engine = engine
    self.showInputs = showInputs
    self.buttonLabel = buttonLabel
    self.basePlaceholder = basePlaceholder
    self.modelPlaceholder = modelPlaceholder
    self.onTestComplete = onTestComplete
  }

  let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
  let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)
  var trimmedAPIKey: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @State var isTesting = false
  @State var resultMessage: String?
  @State var success: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if showInputs {
        VStack(alignment: .leading, spacing: 6) {
          Text("Base URL")
            .font(.custom("Nunito", size: 12))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.secondary)
          TextField(basePlaceholder ?? engine.defaultBaseURL, text: $baseURL)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Model ID")
            .font(.custom("Nunito", size: 12))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.secondary)
          TextField(
            modelPlaceholder ?? LocalModelPreferences.defaultModelId(for: engine), text: $modelId
          )
          .textFieldStyle(.roundedBorder)
        }

        if engine == .custom {
          VStack(alignment: .leading, spacing: 6) {
            Text("API key (optional)")
              .font(.custom("Nunito", size: 12))
              .fontWeight(.semibold)
              .foregroundColor(SettingsStyle.secondary)
            SecureField("sk-live-...", text: $apiKey)
              .textFieldStyle(.roundedBorder)
              .disableAutocorrection(true)
            Text(
              "Stored locally in UserDefaults and sent as a Bearer token for custom endpoints (LiteLLM, OpenRouter, etc.)"
            )
            .font(.custom("Nunito", size: 11))
            .foregroundColor(SettingsStyle.meta)
          }
        }
      }

      SettingsPrimaryButton(
        title: isTesting ? "Testing…" : buttonLabel,
        systemImage: "bolt.fill",
        isLoading: isTesting,
        action: runTest
      )

      if success {
        SettingsStatusDot(state: .good, label: "Test successful.")
      } else if let msg = resultMessage {
        VStack(alignment: .leading, spacing: 6) {
          SettingsStatusDot(state: .bad, label: msg)
          Text(
            "If you get stuck here, you can go back and choose the ‘Bring your own key’ option — it only takes a minute to set up."
          )
          .font(.custom("Nunito", size: 12))
          .foregroundColor(SettingsStyle.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
  func runTest() {
    guard !isTesting else { return }
    isTesting = true
    success = false
    resultMessage = nil

    guard let url = LocalEndpointUtilities.chatCompletionsURL(baseURL: baseURL) else {
      resultMessage = "Invalid base URL"
      isTesting = false
      onTestComplete(false)
      return
    }

    let payload = LocalLLMChatRequest(
      model: modelId,
      messages: [
        LocalLLMChatMessage(
          role: "user",
          content: [
            .text(LocalLLMTestConstants.prompt),
            .imageDataURL(LocalLLMTestConstants.blankImageDataURL),
          ]
        )
      ],
      maxTokens: 10
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if engine == .lmstudio {
      request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
    }
    if engine == .custom && !trimmedAPIKey.isEmpty {
      request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
    }
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    request.httpBody = try? encoder.encode(payload)
    request.timeoutInterval = 35

    let startedAt = Date()

    URLSession.shared.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        let duration = Date().timeIntervalSince(startedAt)
        if duration > LocalLLMTestConstants.maxLatency {
          self.resultMessage = LocalLLMTestConstants.slowMachineMessage
          self.success = false
          self.isTesting = false
          self.onTestComplete(false)
          return
        }
        if let error = error {
          self.resultMessage = error.localizedDescription
          self.isTesting = false
          self.onTestComplete(false)
          return
        }
        guard let http = response as? HTTPURLResponse, let data = data else {
          self.resultMessage = "No response"
          self.isTesting = false
          self.onTestComplete(false)
          return
        }
        if http.statusCode == 200 {
          // Success: don't print raw response body; keep UI clean
          self.resultMessage = nil
          self.success = true
          self.isTesting = false
          self.onTestComplete(true)
        } else {
          let body = String(data: data, encoding: .utf8) ?? ""
          self.resultMessage = "HTTP \(http.statusCode): \(body)"
          self.isTesting = false
          self.onTestComplete(false)
        }
      }
    }.resume()
  }
}

struct LocalLLMChatRequest: Codable {
  let model: String
  let messages: [LocalLLMChatMessage]
  let maxTokens: Int
}

struct LocalLLMChatMessage: Codable {
  let role: String
  let content: [LocalLLMChatContent]
}

struct LocalLLMChatContent: Codable {
  let type: String
  let text: String?
  let imageURL: LocalLLMChatImageURL?

  static func text(_ value: String) -> LocalLLMChatContent {
    LocalLLMChatContent(type: "text", text: value, imageURL: nil)
  }

  static func imageDataURL(_ url: String) -> LocalLLMChatContent {
    LocalLLMChatContent(type: "image_url", text: nil, imageURL: LocalLLMChatImageURL(url: url))
  }
}

struct LocalLLMChatImageURL: Codable {
  let url: String
}
