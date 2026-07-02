//
//  DayflowSignInSheet.swift
//  Dayflow
//
//  Email + verification-code sign-in sheet used from Settings > Account.
//

import SwiftUI

struct DayflowSignInSheet: View {
  private enum Step {
    case email
    case code
  }

  private enum Field {
    case email
    case code
  }

  @ObservedObject private var authManager = DayflowAuthManager.shared
  @FocusState private var focusedField: Field?

  let onDismiss: () -> Void

  @State private var step: Step = .email
  @State private var emailAddress = ""
  @State private var verificationEmail: String?
  @State private var verificationCode = ""
  @State private var didAutoSubmitCode = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header

      switch step {
      case .email:
        emailForm
      case .code:
        codeForm
      }

      if let errorText = authManager.errorText {
        Text(errorText)
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.destructive)
          .textSelection(.enabled)
      }
    }
    .padding(26)
    .background(Color.white)
    .onAppear {
      emailAddress = authManager.signedInEmail ?? emailAddress
      focusedField = step == .email ? .email : .code
    }
    .onChange(of: authManager.isSignedIn) { _, isSignedIn in
      guard isSignedIn else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        onDismiss()
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(step == .email ? "Sign in to Dayflow" : "Check your email")
        .font(.custom("InstrumentSerif-Regular", size: 30))
        .foregroundColor(SettingsStyle.text)

      Text(
        step == .email
          ? "Enter your email and Dayflow will send a 6 digit code."
          : "Enter the code sent to \(verificationEmail ?? authManager.pendingEmail ?? emailAddressTrimmed)."
      )
      .font(.custom("Figtree", size: 13))
      .foregroundColor(SettingsStyle.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var emailForm: some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField("you@example.com", text: $emailAddress)
        .textFieldStyle(.roundedBorder)
        .font(.custom("Figtree", size: 14))
        .focused($focusedField, equals: .email)
        .disabled(authManager.isBusy)
        .onSubmit { sendCode() }

      HStack(spacing: 10) {
        SettingsPrimaryButton(
          title: "Continue",
          systemImage: "arrow.right",
          isLoading: authManager.isBusy,
          isDisabled: emailAddressTrimmed.isEmpty,
          action: sendCode
        )

        SettingsSecondaryButton(
          title: "Cancel",
          isDisabled: authManager.isBusy,
          action: onDismiss
        )
      }
    }
  }

  private var codeForm: some View {
    VStack(alignment: .leading, spacing: 14) {
      TextField("000000", text: $verificationCode)
        .textFieldStyle(.plain)
        .font(.system(size: 30, weight: .semibold, design: .monospaced))
        .multilineTextAlignment(.center)
        .tracking(8)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.04))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(SettingsStyle.divider, lineWidth: 1)
        )
        .focused($focusedField, equals: .code)
        .disabled(authManager.isBusy)
        .onChange(of: verificationCode) { _, newValue in
          let digits = String(newValue.filter(\.isNumber).prefix(6))
          if digits != newValue {
            verificationCode = digits
          }
          guard digits.count == 6, !didAutoSubmitCode, !authManager.isBusy else { return }
          didAutoSubmitCode = true
          verifyCode()
        }
        .onSubmit { verifyCode() }

      HStack(spacing: 10) {
        SettingsPrimaryButton(
          title: "Verify",
          systemImage: "checkmark",
          isLoading: authManager.isBusy,
          isDisabled: verificationCodeTrimmed.count != 6,
          action: verifyCode
        )

        SettingsSecondaryButton(
          title: "Resend",
          isDisabled: authManager.isBusy,
          action: {
            Task {
              didAutoSubmitCode = false
              verificationCode = ""
              await authManager.sendCode(to: verificationEmail ?? emailAddressTrimmed)
              verificationEmail = authManager.pendingEmail ?? verificationEmail
              focusedField = .code
            }
          }
        )

        SettingsSecondaryButton(
          title: "Change email",
          isDisabled: authManager.isBusy,
          action: {
            authManager.useDifferentEmail()
            verificationEmail = nil
            verificationCode = ""
            didAutoSubmitCode = false
            step = .email
            focusedField = .email
          }
        )
      }
    }
  }

  private func sendCode() {
    guard !emailAddressTrimmed.isEmpty else { return }
    Task {
      await authManager.sendCode(to: emailAddressTrimmed)
      if authManager.canVerifyCode, authManager.errorText == nil {
        verificationEmail = authManager.pendingEmail ?? emailAddressTrimmed
        verificationCode = ""
        didAutoSubmitCode = false
        step = .code
        focusedField = .code
      }
    }
  }

  private func verifyCode() {
    guard verificationCodeTrimmed.count == 6 else { return }
    guard let email = verificationEmail ?? authManager.pendingEmail else {
      step = .email
      focusedField = .email
      return
    }
    Task {
      await authManager.verifyCode(verificationCodeTrimmed, for: email)
      if authManager.errorText != nil {
        didAutoSubmitCode = false
      }
    }
  }

  private var emailAddressTrimmed: String {
    emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var verificationCodeTrimmed: String {
    String(verificationCode.filter(\.isNumber).prefix(6))
  }
}
