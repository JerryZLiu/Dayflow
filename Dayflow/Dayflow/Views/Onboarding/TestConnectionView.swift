//
//  TestConnectionView.swift
//  Dayflow
//
//  Test connection button for Gemini API
//

import SwiftUI

struct TestConnectionView: View {
    let onTestComplete: ((Bool) -> Void)?

    @State private var isTesting = false
    @State private var testResult: TestResult?
    init(onTestComplete: ((Bool) -> Void)? = nil) {
        self.onTestComplete = onTestComplete
    }
    
    enum TestResult {
        case success(String)
        case failure(String)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Test button
            DayflowSurfaceButton(
                action: testConnection,
                content: {
                    HStack(spacing: 12) {
                        if isTesting {
                            ProgressView().scaleEffect(0.8).frame(width: 16, height: 16)
                        } else {
                            Image(systemName: testResult == nil ? "bolt.fill" : (testResult?.isSuccess == true ? "checkmark.circle.fill" : "xmark.circle.fill"))
                                .font(.system(size: 14, weight: .medium))
                        }
                        Text(buttonTitle)
                            .font(.custom("Nunito", size: 14))
                            .fontWeight(.semibold)
                    }
                    .frame(minWidth: 200, alignment: .center)
                },
                background: buttonBackground,
                foreground: testResult?.isSuccess == true ? .black : .white,
                borderColor: buttonBorder,
                cornerRadius: 4,
                horizontalPadding: 24,
                verticalPadding: 13
            )
            .disabled(isTesting)
            
            // Result message
            if let result = testResult {
                HStack(spacing: 8) {
                    Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(result.isSuccess ? Color(red: 0.34, green: 1, blue: 0.45) : Color(hex: "E91515"))
                    
                    Text(result.message)
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(result.isSuccess ? .black.opacity(0.7) : Color(hex: "E91515"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(result.isSuccess ? 
                              Color(red: 0.34, green: 1, blue: 0.45).opacity(0.1) : 
                              Color(hex: "E91515").opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(result.isSuccess ? 
                               Color(red: 0.34, green: 1, blue: 0.45).opacity(0.3) : 
                               Color(hex: "E91515").opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
    
    private var buttonTitle: String {
        if isTesting {
            return "Testing connection..."
        } else if testResult?.isSuccess == true {
            return "Test Successful!"
        } else if testResult?.isSuccess == false {
            return "Test Failed - Try Again"
        } else {
            return "Test Connection"
        }
    }
    
    private var buttonBackground: Color {
        if testResult?.isSuccess == true {
            return Color(red: 0.34, green: 1, blue: 0.45).opacity(0.2)
        } else {
            return Color(red: 1, green: 0.42, blue: 0.02)
        }
    }

    private var buttonBorder: Color {
        if testResult?.isSuccess == true {
            return Color(red: 0.34, green: 1, blue: 0.45).opacity(0.5)
        } else {
            return Color.clear
        }
    }
    
    private func testConnection() {
        guard !isTesting else { return }
        
        // Get API key from keychain
        guard let apiKey = KeychainManager.shared.retrieve(for: "gemini") else {
            testResult = .failure("No API key found. Please enter your API key first.")
            onTestComplete?(false)
            AnalyticsService.shared.capture("connection_test_failed", ["provider": "gemini", "error_code": "no_api_key"]) 
            return
        }
        
        isTesting = true
        testResult = nil
        AnalyticsService.shared.capture("connection_test_started", ["provider": "gemini"]) 
        
        Task {
            do {
                let _ = try await GeminiAPIHelper.shared.testConnection(apiKey: apiKey)
                await MainActor.run {
                    testResult = .success("Connection successful! Your API key is working.")
                    isTesting = false
                    onTestComplete?(true)
                }
                AnalyticsService.shared.capture("connection_test_succeeded", ["provider": "gemini"]) 
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                    onTestComplete?(false)
                }
                AnalyticsService.shared.capture("connection_test_failed", ["provider": "gemini", "error_code": String((error as NSError).code)])
            }
        }
    }
}

extension TestConnectionView.TestResult {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
    
    var message: String {
        switch self {
        case .success(let msg): return msg
        case .failure(let msg): return msg
        }
    }
}

// Color extension removed - already defined elsewhere in the project
