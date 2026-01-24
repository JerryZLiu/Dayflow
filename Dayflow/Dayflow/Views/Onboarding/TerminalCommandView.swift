//
//  TerminalCommandView.swift
//  Dayflow
//
//  Terminal command display with copy functionality
//

import SwiftUI
import AppKit

struct TerminalCommandView: View {
    let title: String
    let subtitle: String
    let command: String
    
    @State private var isCopied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.custom("Nunito", size: 16))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.9))
            
            Text(subtitle)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.6))
            
            // Command block with trailing copy button (overlay for tight right alignment)
            ZStack(alignment: .leading) {
                // Command text area
                Text(command)
                    .font(.custom("SF Mono", size: 13))
                    .foregroundColor(.black.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .padding(.trailing, 120) // reserve space so text doesn't sit under the button
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .trailing) {
                DayflowSurfaceButton(
                    action: copyCommand,
                    content: {
                        HStack(spacing: 6) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                            Text(isCopied ? "Copied" : "Copy")
                                .font(.custom("Nunito", size: 13))
                                .fontWeight(.medium)
                        }
                        .foregroundColor(isCopied ? Color(red: 0.34, green: 1, blue: 0.45) : .black.opacity(0.75))
                    },
                    background: Color.white.opacity(0.93),
                    foreground: .black,
                    borderColor: Color.black.opacity(0.12),
                    cornerRadius: 6,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    showShadow: false
                )
                .padding(.trailing, 6)
                .padding(.vertical, 6)
            }
            .background(Color(hex: "F8F9FA"))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
    }
    
    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        
        // Track copy (without sending command content)
        AnalyticsService.shared.capture("terminal_command_copied", [
            "title": title
        ])

        withAnimation(.easeInOut(duration: 0.2)) {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopied = false
            }
        }
    }
}
