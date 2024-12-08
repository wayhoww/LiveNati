//
//  ContentView.swift
//  livetran
//
//  Created by Weihao Wang on 2024/12/7.
//

import SwiftUI
import Foundation
import Translation
import Vision
import CoreImage
import ScreenCaptureKit

@MainActor
func captureImageAsync() async throws -> (CGImage, CGFloat)? {
    guard let display = try? await SCShareableContent.current.displays[0] else {
        return nil;
    }
    guard let matchingScreen = NSScreen.screens.first(where: { $0.frame == display.frame }) else {
        return nil;
    }
    guard let excludedApps = try? await SCShareableContent.current.applications.filter({ app in
        return Bundle.main.bundleIdentifier == app.bundleIdentifier
    }) else {
        return nil;
    }
    
    let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: []);
    
    let scaleFactor = matchingScreen.backingScaleFactor;
    
    let config = SCStreamConfiguration();
    config.width = Int(CGFloat(display.width) * scaleFactor);
    config.height = Int(CGFloat(display.height) * scaleFactor);

    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config);
    
    return (image, scaleFactor);
}


struct RecognizedText {
    let text: String
    let position: CGPoint
    let size: CGSize
};


func recognizeText(image: CGImage, languages: [String]) -> [RecognizedText]? {
    var observations: [VNRecognizedTextObservation]? = nil;
    let request = VNRecognizeTextRequest { (request, error) in
        observations = request.results as? [VNRecognizedTextObservation];
    }
    request.recognitionLevel = .accurate;
    request.recognitionLanguages = languages
    let handler = VNImageRequestHandler(cgImage: image);
    try? handler.perform([request]);
    guard let observations = observations else { return nil; };
    
    return observations
        .filter{ $0.confidence > 0.8 }
        .map {ob in
            let bbox = ob.boundingBox;
            return RecognizedText(
                text: ob.topCandidates(1).first!.string,
                position: CGPoint(
                    x: bbox.origin.x * Double(image.width),
                    y: (1 - bbox.origin.y) * Double(image.height)),
                size: CGSize(
                    width: bbox.size.width * Double(image.width),
                    height: bbox.size.height * Double(image.height)
                )
            );
    };
}


struct WithID<T>: Identifiable {
    let id: Int
    let value: T
}

struct SettingView: View {
    @EnvironmentObject var appData: AppData
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        Form {
            Slider(value: $appData.offsetX, in: -100.0...100.0) { Text("Offset - X") }
            Slider(value: $appData.offsetY, in: -100.0...100.0) { Text("Offset - Y") }
            Slider(value: $appData.scale, in: 0.1...2.0) { Text("Scale") }
            Slider(value: $appData.opacity, in: 0.0...1.0) { Text("Opacity") }
            Picker("Language", selection: $appData.language) {
                ForEach (Language.allCases.enumerated().map { WithID(id: $0, value: $1) }) { c in
                    Text(c.value.rawValue).tag(c.value)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .onAppear { openWindow(id: "livenati_overlay") }
    }
}


struct TranslationBlock : Identifiable {
    let id: Int
    let text: String
    let position: CGPoint
    let size: CGSize
}


struct AutoResizableText: View {
    let text: String
    let minFontSize: CGFloat
    let maxFontSize: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(.system(size: maxFontSize))
                .minimumScaleFactor(minFontSize / maxFontSize)
                .lineLimit(1)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}


func compareImages(image1: CGImage, image2: CGImage) -> Bool {
    let ciImage1 = CIImage(cgImage: image1)
    let ciImage2 = CIImage(cgImage: image2)
    
    let diffFilter = CIFilter(name: "CIDifferenceBlendMode")!
    diffFilter.setValue(ciImage1, forKey: kCIInputImageKey)
    diffFilter.setValue(ciImage2, forKey: kCIInputBackgroundImageKey)
    
    let areaMaxFilter = CIFilter(name: "CIAreaMaximum")!
    areaMaxFilter.setValue(diffFilter.outputImage, forKey: kCIInputImageKey)
    
    let context = CIContext()
    var pixelBuffer = [UInt8](repeating: 0, count: 4)
    context.render(
        areaMaxFilter.outputImage!,
        toBitmap: &pixelBuffer,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: nil
    )
    
    return pixelBuffer[0] == 0 && pixelBuffer[1] == 0 && pixelBuffer[2] == 0
}

func getLineHeight(fontSize: CGFloat) -> CGFloat {
    let font = CTFont(.system, size: fontSize);
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let leading = CTFontGetLeading(font)
    return ascent + abs(descent) + leading
}

struct OverlayView: View {
    @EnvironmentObject var appData: AppData
    
    @State private var configuration: TranslationSession.Configuration = .init(source: Locale.Language(identifier: "en-US"))
    @State private var pendingBlocks: [TranslationBlock] = []
    @State private var translatedBlocks: [TranslationBlock] = []
    
    @State private var translationCache: [String: String] = [:]
    @State private var lastImage: CGImage? = nil
    @State private var pendingCnt: Int = 0;
    
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                let globalFrame = geometry.frame(in: .global)
                let localFrame = geometry.frame(in: .local)
                let menuBarHeight = NSScreen.main!.frame.height - NSScreen.main!.visibleFrame.height
                let fontDefaultSize = 16.0;
                let fontDefaultHeight = getLineHeight(fontSize: fontDefaultSize);
                let typicalFontSizes = [10.0, 16.0, 22.0, 30.0, 45.0, 60.0, 80.0, 120.0, 180.0, 240.0, 300.0, 400.0]
                

                ForEach(translatedBlocks) { item in
                    let desiredSize = item.size.height / fontDefaultHeight * fontDefaultSize;
                    let typicalSize = typicalFontSizes.last(where: {$0 <= desiredSize}) ?? typicalFontSizes.first!;
                    Text(item.text)
                        .font(.system(size: typicalSize.scaled(by: appData.scale)))
                        .foregroundColor(.black)
                        .background(Color.white)
                        .opacity(appData.opacity)
                        .frame(width: item.size.width, height: item.size.height, alignment: Alignment.topLeading)
                        .position(
                            x: item.position.x + item.size.width / 2 + appData.offsetX + (localFrame.minX - globalFrame.minX),
                            y: item.position.y - item.size.height / 2 + appData.offsetY + (localFrame.minY - globalFrame.minY) - menuBarHeight
                        )
                }
            }
        }
        .translationTask(configuration) { session in
            Task { @MainActor in
                pendingCnt -= 1
                
                let localPendingBlocks = pendingBlocks;
                let requests = localPendingBlocks
                    .filter { item in translationCache[item.text] == nil }
                    .map { item in TranslationSession.Request(sourceText: item.text) }
                let response = session.translate(batch: requests)
                for try await res in response {
                    translationCache[res.sourceText] = res.targetText
                }
                translatedBlocks = localPendingBlocks.map { item in
                    TranslationBlock(id: item.id, text: translationCache[item.text] ?? "<error>", position: item.position, size: item.size)
                }
            }
        }
        .onReceive(timer) { _ in
            Task {
                let (image, scaleFactor) = try! await captureImageAsync()!;
                
                if let lastImageV = lastImage {
                    if compareImages(image1: lastImageV, image2: image) {
                        return;
                    }
                }
                
                if pendingCnt >= 0 {
                    return
                }
                
                lastImage = image;
                
                let recognizedTexts = recognizeText(image: image, languages: [appData.language.asLanguage()]);
                pendingBlocks = recognizedTexts!.enumerated().map({(i, rec) in
                    return TranslationBlock(
                        id: i,
                        text: rec.text,
                        position: CGPoint(x: rec.position.x / scaleFactor, y: rec.position.y / scaleFactor),
                        size: CGSize(width: rec.size.width / scaleFactor, height: rec.size.height / scaleFactor)
                    )
                })
                pendingCnt += 1
                configuration.invalidate();
            }
        }
        .onReceive(appData.ocrAndTranslationConfigChanged) {
            print("locale did set")
            lastImage = nil
            configuration = TranslationSession.Configuration(source: Locale.Language(identifier: appData.language.asLocale()))
        }
    }
}

#Preview {
    OverlayView()
}
