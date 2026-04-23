//
//  ApfelLanguageModel.swift
//  Dayflow
//
//  Wraps Apple's on-device language model (FoundationModels, macOS 26+).
//  Availability-gated so the binary still builds and runs on older macOS;
//  `isAvailable` is the single runtime check callers use before constructing
//  anything that actually talks to the model.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum ApfelAvailability: Equatable {
  case available
  case unsupportedOS
  case modelNotReady
  case appleIntelligenceDisabled
  case unknown(String)

  var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  var userFacingReason: String {
    switch self {
    case .available:
      return "Available"
    case .unsupportedOS:
      return "Requires macOS 26 or later."
    case .modelNotReady:
      return "Apple Intelligence is still downloading or preparing."
    case .appleIntelligenceDisabled:
      return "Enable Apple Intelligence in System Settings to use this provider."
    case .unknown(let detail):
      return detail
    }
  }
}

struct ApfelLanguageModel {
  static var availability: ApfelAvailability {
    if #available(macOS 26.0, *) {
      #if canImport(FoundationModels)
      return SystemLanguageModel.default.availability == .available
        ? .available
        : .modelNotReady
      #else
      return .unsupportedOS
      #endif
    }
    return .unsupportedOS
  }

  /// Generate a single text completion for the given prompt.
  /// Throws if Apple Intelligence is unavailable on this device/OS.
  func generate(prompt: String, systemInstructions: String? = nil) async throws -> String {
    guard #available(macOS 26.0, *) else {
      throw ApfelRuntimeError.unsupportedOS
    }
    #if canImport(FoundationModels)
    return try await Self.generateOnSupportedOS(
      prompt: prompt, systemInstructions: systemInstructions)
    #else
    throw ApfelRuntimeError.frameworkMissing
    #endif
  }

  #if canImport(FoundationModels)
  @available(macOS 26.0, *)
  private static func generateOnSupportedOS(
    prompt: String, systemInstructions: String?
  ) async throws -> String {
    let session: LanguageModelSession
    if let systemInstructions {
      session = LanguageModelSession(instructions: systemInstructions)
    } else {
      session = LanguageModelSession()
    }
    let response = try await session.respond(to: prompt)
    return response.content
  }
  #endif

}

enum ApfelRuntimeError: Error, LocalizedError {
  case unsupportedOS
  case frameworkMissing
  case generationFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedOS:
      return "Apple Intelligence requires macOS 26 or later."
    case .frameworkMissing:
      return "FoundationModels framework is not available in this build."
    case .generationFailed(let detail):
      return "Apple Intelligence failed to generate a response: \(detail)"
    }
  }
}
