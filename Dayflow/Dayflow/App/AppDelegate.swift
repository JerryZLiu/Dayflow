//
//  AppDelegate.swift
//  Dayflow
//
//  Created by Jerry Liu on 4/26/25.
//

import AppKit
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var recorder : ScreenRecorder!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusBar = StatusBarController()   // safe: AppKit is ready, main thread
        recorder  = ScreenRecorder()        // hooks into AppState
        try? SMAppService.mainApp.register()// autostart at login
        
        // Start the Gemini analysis background job
        setupGeminiAnalysis()
    }
    
    // Start Gemini analysis as a background task
    private func setupGeminiAnalysis() {
        // Perform after a short delay to ensure other initialization completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AnalysisManager.shared.startAnalysisJob()
            print("AppDelegate: Gemini analysis job started")
        }
    }
}
