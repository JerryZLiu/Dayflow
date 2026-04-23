import Foundation

extension GeminiDirectProvider {
  // MARK: - Error Classification for Unified Retry

  enum RetryStrategy {
    case immediate  // Parsing/encoding errors - retry immediately
    case shortBackoff  // Network timeouts - retry with 2s, 4s, 8s
    case longBackoff  // Rate limits - retry with 30s, 60s, 120s
    case enhancedPrompt  // Validation errors - retry with enhanced prompt
    case noRetry  // Auth/permanent errors - don't retry
  }

  func fallbackReason(for code: Int) -> String {
    switch code {
    case 429:
      return "rate_limit_429"
    case 503:
      return "service_unavailable_503"
    case 403:
      return "forbidden_quota_403"
    default:
      return "http_\(code)"
    }
  }

  func classifyError(_ error: Error) -> RetryStrategy {
    // JSON/Parsing errors - should retry immediately (different LLM response likely)
    if error is DecodingError {
      return .immediate
    }

    // Network/Transport errors
    if let nsError = error as NSError? {
      switch nsError.domain {
      case NSURLErrorDomain:
        switch nsError.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
          NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
          NSURLErrorNotConnectedToInternet:
          return .shortBackoff
        default:
          return .noRetry
        }

      case "GeminiError":
        switch nsError.code {
        // Rate limiting
        case 429:
          return .longBackoff
        // Server errors
        case 500...599:
          return .shortBackoff
        // Auth errors
        case 401, 403:
          return .noRetry
        // Parsing/encoding errors
        case 7, 9, 10:
          return .immediate
        // Client errors (bad request, etc)
        case 400...499:
          return .noRetry
        default:
          return .shortBackoff
        }

      default:
        break
      }
    }

    // Default: short backoff for unknown errors
    return .shortBackoff
  }

  func delayForStrategy(_ strategy: RetryStrategy, attempt: Int) -> TimeInterval {
    switch strategy {
    case .immediate:
      return 0
    case .shortBackoff:
      return pow(2.0, Double(attempt)) * 2.0  // 2s, 4s, 8s
    case .longBackoff:
      return Double(min(3, attempt + 1))  // 1s, 2s, 3s (capped)
    case .enhancedPrompt:
      return 1.0  // Brief delay for enhanced prompt
    case .noRetry:
      return 0
    }
  }
}
