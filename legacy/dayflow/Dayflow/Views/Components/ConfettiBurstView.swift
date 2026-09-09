//
//  ConfettiBurstView.swift
//  Dayflow
//
//  Lightweight celebratory burst used by app surfaces.
//

import SwiftUI

struct ConfettiBurstView: View {
  let trigger: Int

  private let colors: [Color] = [
    Color(hex: "FF6B6B"),
    Color(hex: "FFD93D"),
    Color(hex: "6BCB77"),
    Color(hex: "4D96FF"),
    Color(hex: "9B5DE5"),
    Color(hex: "FF8FAB"),
    Color(hex: "00C2FF"),
    Color(hex: "FFA41B"),
    Color(hex: "F72585"),
    Color(hex: "7AE582"),
  ]
  private let confettiCount = 60

  var body: some View {
    ZStack {
      ForEach(0..<confettiCount, id: \.self) { index in
        ConfettiPiece(
          color: colors[index % colors.count],
          trigger: trigger
        )
      }
    }
    .allowsHitTesting(false)
  }
}

private struct ConfettiPiece: View {
  let color: Color
  let trigger: Int
  @State private var offset: CGSize = .zero
  @State private var rotation: Double = 0
  @State private var opacity: Double = 0

  var body: some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(color)
      .frame(width: 6, height: 10)
      .rotationEffect(.degrees(rotation))
      .offset(offset)
      .opacity(opacity)
      .onChange(of: trigger) {
        let xStart = Double.random(in: -60...60)
        let xBurst = Double.random(in: -220...220)
        let xFall = Double.random(in: -340...340)
        let yBurst = Double.random(in: -30...50)
        let yFall = Double.random(in: 200...360)
        let spinBurst = Double.random(in: -120...120)
        let spinFall = spinBurst + Double.random(in: -240...240)

        offset = CGSize(width: xStart, height: -6)
        rotation = 0
        opacity = 1

        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
          offset = CGSize(width: xBurst, height: yBurst)
          rotation = spinBurst
        }

        withAnimation(.easeInOut(duration: 1.6).delay(0.3)) {
          offset = CGSize(width: xFall, height: yFall)
          rotation = spinFall
        }

        withAnimation(.easeOut(duration: 0.4).delay(1.6)) {
          opacity = 0
        }
      }
  }
}
