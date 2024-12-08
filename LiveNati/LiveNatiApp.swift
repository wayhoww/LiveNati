//
//  LiveNatiApp.swift
//  LiveNati
//
//  Created by Weihao Wang on 2024/12/7.
//

import SwiftUI
import AppKit
import Combine

enum Language: String, CaseIterable {
    case chinese = "Chinese"
    case japanese = "Japanese"
    case korean = "Korean"
    case english = "English"
    
    func asLanguage() -> String {
        switch self {
        case .chinese: "zh"
        case .japanese: "ja"
        case .korean: "ko"
        case .english: "en"
        }
    }
    
    func asRegion() -> String {
        switch self {
        case .chinese: "CN"
        case .japanese: "JP"
        case .korean: "KR"
        case .english: "US"
        }
    }
    
    func asLocale() -> String {
        return "\(asLanguage())-\(asRegion())"
    }
}

class AppData: ObservableObject {
    @AppStorage("offsetX") public var offsetX: Double = 0.0;
    @AppStorage("offsetY") public var offsetY: Double = 0.0;
    @AppStorage("scale") public var scale: Double = 1.0;
    @AppStorage("opacity") public var opacity: Double = 1.0;
    @AppStorage("language") public var language: Language = Language.english {
        didSet { ocrAndTranslationConfigChanged.send() }
    }
    
    var ocrAndTranslationConfigChanged = PassthroughSubject<Void, Never>();
}

@main
struct LiveNatiApp: App {
    @StateObject private var appData = AppData()
    
    var body: some Scene {
        WindowGroup {
            SettingView().environmentObject(appData)
        }

        WindowGroup(id: "livenati_overlay") {
            OverlayView()
                .environmentObject(appData)
                .navigationTitle("LiveNati Overlay")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .onAppear { setupTransparentWindow() }
        }.windowStyle(HiddenTitleBarWindowStyle()).restorationBehavior(.disabled)
    }
    
    func setupTransparentWindow() {
        if let window = NSApplication.shared.windows.filter({ $0.title == "LiveNati Overlay" }).first {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.setFrame(NSScreen.main!.frame, display: true)
        }
    }
}
