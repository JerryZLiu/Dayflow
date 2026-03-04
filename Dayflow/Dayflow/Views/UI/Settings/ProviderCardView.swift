//
//  ProviderCardView.swift
//  Dayflow
//
//  Compact provider card for the Settings providers tab
//

import SwiftUI

struct ProviderCardView: View {
    let provider: CompactProviderInfo
    let isPrimary: Bool
    let isSecondary: Bool
    let isConfigured: Bool
    let statusDetail: String?
    let canSetPrimary: Bool
    let canSetSecondary: Bool

    let onEdit: () -> Void
    let onConfigure: () -> Void
    let onRemove: () -> Void
    let onSetPrimary: () -> Void
    let onSetSecondary: () -> Void

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    private let buttonTextWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            summaryText
            actionButtons
        }
        .padding(14)
        .background(isPrimary ? Color(hex: "FFF8EE") : Color.white.opacity(0.52))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isPrimary ? Color(hex: "FFE0A5") : Color.black.opacity(0.06),
                    lineWidth: isPrimary ? 1.2 : 1
                )
        )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            ProviderIconView(icon: provider.icon)
                .scaleEffect(0.7)
                .frame(width: 28, height: 28)

            Text(provider.providerTableName)
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.82))

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isPrimary {
            BadgeView(text: "PRIMARY", type: .orange)
        } else if isSecondary {
            BadgeView(text: "SECONDARY", type: .blue)
        } else if isConfigured {
            BadgeView(text: "CONFIGURED", type: .green)
        } else {
            BadgeView(text: "NOT SET", type: .green)
                .opacity(0.5)
        }
    }

    // MARK: - Summary

    private var summaryText: some View {
        Text(statusDetail ?? provider.summary)
            .font(.custom("Nunito", size: 12))
            .foregroundColor(.black.opacity(0.54))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConfigured {
                configuredActions
            } else {
                unconfiguredActions
            }
            roleActions
        }
    }

    private var configuredActions: some View {
        HStack(spacing: 8) {
            cardButton("Edit", filled: false, action: onEdit)
            cardButton("Remove", style: .destructive, action: onRemove)
        }
    }

    private var unconfiguredActions: some View {
        HStack(spacing: 8) {
            cardButton("Configure", filled: true, action: onConfigure)
        }
    }

    @ViewBuilder
    private var roleActions: some View {
        let showPrimary = !isPrimary && canSetPrimary
        let showSecondary = !isSecondary && canSetSecondary

        if showPrimary || showSecondary {
            HStack(spacing: 8) {
                if showPrimary {
                    cardButton("Set as Primary", filled: true, action: onSetPrimary)
                }
                if showSecondary {
                    cardButton("Set as Secondary", filled: true, action: onSetSecondary)
                }
            }
        }
    }

    // MARK: - Button Helpers

    private enum ButtonStyle {
        case normal
        case destructive
    }

    private func cardButton(
        _ title: String,
        filled: Bool = false,
        style: ButtonStyle = .normal,
        action: @escaping () -> Void
    ) -> some View {
        let bg: Color
        let fg: Color
        let border: Color

        switch style {
        case .destructive:
            bg = .white
            fg = Color.red.opacity(0.7)
            border = Color.red.opacity(0.2)
        case .normal:
            if filled {
                bg = accentColor
                fg = .white
                border = .clear
            } else {
                bg = .white
                fg = .black
                border = Color.black.opacity(0.14)
            }
        }

        return DayflowSurfaceButton(
            action: action,
            content: {
                Text(title)
                    .font(.custom("Nunito", size: 12))
                    .fontWeight(.semibold)
                    .frame(width: buttonTextWidth, alignment: .center)
            },
            background: bg,
            foreground: fg,
            borderColor: border,
            cornerRadius: 7,
            horizontalPadding: 10,
            verticalPadding: 5,
            showOverlayStroke: filled
        )
    }

    private func cardButton(
        _ title: String,
        style: ButtonStyle,
        action: @escaping () -> Void
    ) -> some View {
        cardButton(title, filled: false, style: style, action: action)
    }
}
