//
//  APIKeyInputView.swift
//  Dayflow
//
//  API key input component for Gemini setup
//

import SwiftUI

struct APIKeyInputView: View {
    @Binding var apiKey: String
    let title: String
    let subtitle: String
    let placeholder: String
    let onValidate: (String) -> Bool
    
    @State private var showPassword = false
    @State private var validationState: ValidationState = .none
    @FocusState private var isFocused: Bool
    
    enum ValidationState {
        case none
        case valid
        case invalid
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.custom("Nunito", size: 16))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.9))
            
            Text(subtitle)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.6))
            
            // Input field container
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Group {
                        if showPassword {
                            TextField(placeholder, text: $apiKey)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField(placeholder, text: $apiKey)
                                .textFieldStyle(.plain)
                        }
                    }
                    .font(.custom("SF Mono", size: 13))
                    .focused($isFocused)
                    .onChange(of: apiKey) { _, newValue in
                        validateKey(newValue)
                    }
                    
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    
                    // Validation indicator
                    if validationState != .none {
                        Image(systemName: validationState == .valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(validationState == .valid ? Color(red: 0.34, green: 1, blue: 0.45) : Color(hex: "E91515"))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.8))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderColor, lineWidth: isFocused ? 2 : 1)
                )
                
                // Validation message
                if validationState == .invalid {
                    Text("API key should start with 'AIza' and be at least 30 characters")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(Color(hex: "E91515"))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: validationState)
            
            // Help text
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.34, green: 1, blue: 0.45).opacity(0.7))
                
                Text("Your API key is encrypted and stored in your macOS Keychain - never uploaded anywhere")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.5))
            }
        }
    }
    
    private var borderColor: Color {
        if isFocused {
            switch validationState {
            case .valid:
                return Color(red: 0.34, green: 1, blue: 0.45).opacity(0.6)
            case .invalid:
                return Color(hex: "E91515").opacity(0.6)
            case .none:
                return Color(red: 1, green: 0.42, blue: 0.02).opacity(0.6)
            }
        } else {
            return Color.black.opacity(0.1)
        }
    }
    
    private func validateKey(_ key: String) {
        guard !key.isEmpty else {
            validationState = .none
            return
        }
        
        withAnimation(.easeOut(duration: 0.2)) {
            validationState = onValidate(key) ? .valid : .invalid
        }
    }
}
