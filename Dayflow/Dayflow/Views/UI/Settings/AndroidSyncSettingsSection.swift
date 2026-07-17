import CoreImage.CIFilterBuiltins
import SwiftUI

struct AndroidSyncSettingsSection: View {
  @ObservedObject private var server = AndroidSyncServer.shared
  @State private var showsPairingCode = false
  @State private var devices: [CaptureDevice] = []

  var body: some View {
    SettingsSection(
      title: "Android capture",
      subtitle: "Receive encrypted recordings over your local network."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          Circle()
            .fill(server.isRunning ? Color.green : SettingsStyle.destructive)
            .frame(width: 8, height: 8)
          Text(server.isRunning ? "Ready on local network" : "Receiver unavailable")
            .font(.custom("Figtree", size: 13).weight(.semibold))
            .foregroundStyle(SettingsStyle.text)
          if let port = server.port {
            Text("Port \(port)")
              .font(.custom("Figtree", size: 11))
              .foregroundStyle(SettingsStyle.meta)
          }
        }

        if devices.isEmpty {
          Text("No Android device paired")
            .font(.custom("Figtree", size: 12))
            .foregroundStyle(SettingsStyle.secondary)
        } else {
          ForEach(devices) { device in
            deviceRow(device)
          }
        }

        HStack(spacing: 12) {
          SettingsPrimaryButton(
            title: showsPairingCode ? "Hide pairing code" : "Pair Android",
            systemImage: showsPairingCode ? "qrcode" : "qrcode.viewfinder",
            action: { showsPairingCode.toggle() }
          )
          SettingsSecondaryButton(
            title: "New pairing code",
            systemImage: "arrow.triangle.2.circlepath",
            action: {
              server.resetPairing()
              showsPairingCode = true
            }
          )
        }

        if showsPairingCode {
          pairingCode
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }

        if let lastSyncAt = server.lastSyncAt {
          Text("Last sync \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.custom("Figtree", size: 12))
            .foregroundStyle(SettingsStyle.statusGood)
        }
        if let error = server.lastError {
          Text(error)
            .font(.custom("Figtree", size: 12))
            .foregroundStyle(SettingsStyle.destructive)
        }
      }
      .animation(.easeOut(duration: 0.18), value: showsPairingCode)
      .onAppear {
        server.start()
        reloadDevices()
      }
      .onChange(of: server.lastSyncAt) { reloadDevices() }
    }
  }

  private func deviceRow(_ device: CaptureDevice) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "smartphone")
        .font(.system(size: 14, weight: .medium))
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(device.displayName)
          .font(.custom("Figtree", size: 13).weight(.semibold))
        Text([device.model, device.osVersion].compactMap { $0 }.joined(separator: " · "))
          .font(.custom("Figtree", size: 11))
          .foregroundStyle(SettingsStyle.meta)
      }
      Spacer(minLength: 8)
      Button {
        StorageManager.shared.revokeCaptureDevice(id: device.id)
        server.resetPairing()
        reloadDevices()
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(SettingsStyle.destructive)
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .help("Remove Android device")
    }
  }

  @ViewBuilder
  private var pairingCode: some View {
    if let payload = server.pairingPayload(),
      let data = try? JSONEncoder().encode(payload),
      let value = String(data: data, encoding: .utf8),
      let image = Self.qrCode(from: value)
    {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: 180, height: 180)
        .padding(10)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.black.opacity(0.08), lineWidth: 1))
        .accessibilityLabel("Android pairing QR code")
    } else {
      ProgressView().controlSize(.small)
    }
  }

  private func reloadDevices() {
    devices = StorageManager.shared.fetchCaptureDevices(includeRevoked: false)
      .filter { $0.platform == .android }
  }

  private static func qrCode(from value: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let context = CIContext()
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
  }
}
