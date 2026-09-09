import Foundation

extension GeminiDirectProvider {
  func uploadAndAwait(
    _ fileURL: URL, mimeType: String, key: String, maxWaitTime: TimeInterval = 3 * 60
  ) async throws -> (fileSize: Int64, fileURI: String) {
    let fileData = try Data(contentsOf: fileURL)
    let fileSize = fileData.count

    // Full cycle retry: upload + processing
    let maxCycles = 3
    var lastError: Error?

    for cycle in 1...maxCycles {
      print("🔄 Upload+Processing cycle \(cycle)/\(maxCycles)")

      var uploadedFileURI: String? = nil

      // Upload with retries
      let maxUploadRetries = 3
      var uploadAttempt = 0

      while uploadAttempt < maxUploadRetries {
        do {
          uploadedFileURI = try await uploadResumable(data: fileData, mimeType: mimeType)
          break  // Upload success, exit upload retry loop
        } catch {
          uploadAttempt += 1
          lastError = error

          // Check if this is a retryable error
          if shouldRetryUpload(error: error) && uploadAttempt < maxUploadRetries {
            let delay = pow(2.0, Double(uploadAttempt))  // Exponential backoff: 2s, 4s, 8s
            print(
              "🔄 Upload attempt \(uploadAttempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)"
            )
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          } else {
            // Either non-retryable error or max upload retries exceeded
            if uploadAttempt >= maxUploadRetries {
              print("❌ Upload failed after \(maxUploadRetries) attempts in cycle \(cycle)")
            }
            break  // Break upload retry loop, will continue to next cycle
          }
        }
      }

      // If upload failed completely, try next cycle
      guard let fileURI = uploadedFileURI else {
        if cycle == maxCycles {
          throw lastError
            ?? NSError(
              domain: "GeminiError", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey: "Failed to upload file after \(maxCycles) cycles"
              ])
        }
        print("🔄 Upload failed in cycle \(cycle), trying next cycle")
        continue
      }

      // Upload succeeded, now poll for processing with 3-minute timeout
      print("✅ Upload succeeded in cycle \(cycle), polling for file processing...")
      let startTime = Date()

      while Date().timeIntervalSince(startTime) < maxWaitTime {
        do {
          let status = try await getFileStatus(fileURI: fileURI)
          if status == "ACTIVE" {
            print("✅ File processing completed in cycle \(cycle)")
            return (Int64(fileSize), fileURI)
          }
        } catch {
          print("⚠️ Error checking file status: \(error.localizedDescription)")
          lastError = error
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
      }

      // Processing timeout occurred
      print("⏰ File processing timeout (3 minutes) in cycle \(cycle)")
      lastError = NSError(
        domain: "GeminiError", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "File processing timeout"])

      if cycle < maxCycles {
        print("🔄 Starting next upload+processing cycle...")
      }
    }

    // All cycles failed
    throw lastError
      ?? NSError(
        domain: "GeminiError", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Upload and processing failed after \(maxCycles) complete cycles"
        ])
  }

  func shouldRetryUpload(error: Error) -> Bool {
    // Retry on network connection issues
    if let nsError = error as NSError? {
      // Network connection lost (error -1005)
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
        return true
      }
      // Connection timeout (error -1001)
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
        return true
      }
      // DNS lookup failed (error -1003)
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotFindHost {
        return true
      }
      // Socket connection issues (various codes)
      if nsError.domain == NSURLErrorDomain
        && (nsError.code == NSURLErrorCannotConnectToHost
          || nsError.code == NSURLErrorNotConnectedToInternet)
      {
        return true
      }
    }

    // Don't retry on API key issues, file format problems, etc.
    return false
  }

  func uploadSimple(data: Data, mimeType: String) async throws -> String {
    var request = URLRequest(url: URL(string: fileEndpoint + "?key=\(apiKey)")!)
    request.httpMethod = "POST"
    request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
    request.httpBody = data

    let requestStart = Date()
    let (responseData, response) = try await URLSession.shared.data(for: request)
    let requestDuration = Date().timeIntervalSince(requestStart)
    let statusCode = (response as? HTTPURLResponse)?.statusCode
    logCallDuration(operation: "upload.simple", duration: requestDuration, status: statusCode)

    if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
      let file = json["file"] as? [String: Any],
      let uri = file["uri"] as? String
    {
      return uri
    }
    // Log unexpected response to help debugging
    logGeminiFailure(context: "uploadSimple", response: response, data: responseData, error: nil)
    throw NSError(
      domain: "GeminiError", code: 3,
      userInfo: [NSLocalizedDescriptionKey: "Failed to parse upload response"])
  }

  func uploadResumable(data: Data, mimeType: String) async throws -> String {
    print("📤 Starting resumable video upload:")
    print("   Size: \(data.count / 1024 / 1024) MB")
    print("   MIME Type: \(mimeType)")

    let metadata = GeminiFileMetadata(file: GeminiFileInfo(displayName: "dayflow_video"))
    let boundary = UUID().uuidString

    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
    body.append(try JSONEncoder().encode(metadata))
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: URL(string: fileEndpoint + "?key=\(apiKey)")!)
    request.httpMethod = "POST"
    request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
    request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
    request.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Raw-Size")
    request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(metadata)

    let startTime = Date()
    let (responseData, response) = try await URLSession.shared.data(for: request)
    let initDuration = Date().timeIntervalSince(startTime)

    guard let httpResponse = response as? HTTPURLResponse else {
      print("🔴 Upload init failed: Non-HTTP response")
      throw NSError(
        domain: "GeminiError", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response during upload init"])
    }

    logCallDuration(
      operation: "upload.init", duration: initDuration, status: httpResponse.statusCode)

    guard let uploadURL = httpResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
      print("🔴 No upload URL in response")
      if let bodyText = String(data: responseData, encoding: .utf8) {
        print("   Response Body: \(truncate(bodyText, max: 1000))")
      }
      logGeminiFailure(
        context: "uploadResumable(start)", response: response, data: responseData, error: nil)
      throw NSError(
        domain: "GeminiError", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No upload URL in response"])
    }

    var uploadRequest = URLRequest(url: URL(string: uploadURL)!)
    uploadRequest.httpMethod = "PUT"
    uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
    uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
    uploadRequest.httpBody = data

    let uploadStartTime = Date()
    let (uploadResponseData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
    let uploadDuration = Date().timeIntervalSince(uploadStartTime)

    guard let httpUploadResponse = uploadResponse as? HTTPURLResponse else {
      print("🔴 Upload finalize failed: Non-HTTP response")
      throw NSError(
        domain: "GeminiError", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response during upload finalize"])
    }

    logCallDuration(
      operation: "upload.finalize", duration: uploadDuration, status: httpUploadResponse.statusCode)

    if httpUploadResponse.statusCode != 200 {
      print("🔴 Upload failed with status \(httpUploadResponse.statusCode)")
      if let bodyText = String(data: uploadResponseData, encoding: .utf8) {
        print("   Response Body: \(truncate(bodyText, max: 1000))")
      }
    }

    if let json = try JSONSerialization.jsonObject(with: uploadResponseData) as? [String: Any],
      let file = json["file"] as? [String: Any],
      let uri = file["uri"] as? String
    {
      return uri
    }

    print("🔴 Failed to parse upload response")
    if let bodyText = String(data: uploadResponseData, encoding: .utf8) {
      print("   Response Body: \(truncate(bodyText, max: 1000))")
    }
    logGeminiFailure(
      context: "uploadResumable(finalize)", response: uploadResponse, data: uploadResponseData,
      error: nil)
    throw NSError(
      domain: "GeminiError", code: 5,
      userInfo: [NSLocalizedDescriptionKey: "Failed to parse upload response"])
  }

  func getFileStatus(fileURI: String) async throws -> String {
    guard let url = URL(string: fileURI + "?key=\(apiKey)") else {
      throw NSError(
        domain: "GeminiError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid file URI"])
    }

    let requestStart = Date()
    let (data, response) = try await URLSession.shared.data(from: url)
    let requestDuration = Date().timeIntervalSince(requestStart)
    let statusCode = (response as? HTTPURLResponse)?.statusCode
    logCallDuration(operation: "file.status", duration: requestDuration, status: statusCode)

    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let state = json["state"] as? String
    {
      return state
    }
    // Unexpected response – log for diagnosis but still return UNKNOWN
    logGeminiFailure(context: "getFileStatus", response: response, data: data, error: nil)
    return "UNKNOWN"
  }

}
