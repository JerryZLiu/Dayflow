//
//  TransparentWindowHelper.swift
//  Dayflow
//
//  Helper to create transparent windows
//

import SwiftUI
import AppKit

// Helper to access the window and make it transparent with glass effect
struct TransparentWindowView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configureGlassWindow(window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configureGlassWindow(window)
        }
    }
    
    private func configureGlassWindow(_ window: NSWindow) {
        // Core transparency settings for glass effect
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        
        // Enable proper vibrancy and blur
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        
        // Window interaction settings
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        
        // Optimize for glass effect performance
        window.displaysWhenScreenProfileChanges = true
        window.invalidateShadow()
        window.viewsNeedDisplay = true
    }
}

// Visual effect for blur background with enhanced glass settings
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = true
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configureVisualEffect(view)
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configureVisualEffect(nsView)
    }
    
    private func configureVisualEffect(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
        
        // Critical for proper glass effect
        view.wantsLayer = true
        view.allowsVibrancy = true
    }
}

// Glass effect background specifically for main content areas
struct GlassEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0
    
    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        cornerRadius: CGFloat = 0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        view.allowsVibrancy = true
        view.wantsLayer = true
        
        if cornerRadius > 0 {
            view.layer?.cornerRadius = cornerRadius
            view.layer?.masksToBounds = true
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        
        if cornerRadius > 0 {
            nsView.layer?.cornerRadius = cornerRadius
        }
    }
}

// Predefined glass styles for consistency
extension GlassEffectBackground {
    static var mainContent: GlassEffectBackground {
        GlassEffectBackground(
            material: .hudWindow,
            blendingMode: .behindWindow
        )
    }
    
    static var sidebar: GlassEffectBackground {
        GlassEffectBackground(
            material: .sidebar,
            blendingMode: .behindWindow
        )
    }
    
    static var card: GlassEffectBackground {
        GlassEffectBackground(
            material: .popover,
            blendingMode: .withinWindow
        )
    }
    
    static var windowBackground: GlassEffectBackground {
        GlassEffectBackground(
            material: .underWindowBackground,
            blendingMode: .behindWindow
        )
    }
}