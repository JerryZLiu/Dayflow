//
//  LogoBadgeView.swift
//  Dayflow
//
//  Plain logo asset renderer.
//

import SwiftUI

struct LogoBadgeView: View {
  let imageName: String
  var size: CGFloat = 100

  var body: some View {
    Image(imageName)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
