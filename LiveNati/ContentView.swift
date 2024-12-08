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


// https://gist.github.com/nicolas-miari/519cb8fd31c16e5daac263412996d08a

enum ImageDiffError: LocalizedError {
  case failedToCreateFilter
  case failedToCreateContext
}

func compareImages(_ leftImage: CGImage, _ rightImage: CGImage) throws -> Bool {
    let left = CIImage(cgImage: leftImage)
    let right = CIImage(cgImage: rightImage)
    
    guard let diffFilter = CIFilter(name: "CIDifferenceBlendMode") else {
        throw ImageDiffError.failedToCreateFilter
    }
    diffFilter.setDefaults()
    diffFilter.setValue(left, forKey: kCIInputImageKey)
    diffFilter.setValue(right, forKey: kCIInputBackgroundImageKey)
    
    // Create the area max filter and set its properties.
    guard let areaMaxFilter = CIFilter(name: "CIAreaMaximum") else {
        throw ImageDiffError.failedToCreateFilter
    }
    areaMaxFilter.setDefaults()
    areaMaxFilter.setValue(diffFilter.value(forKey: kCIOutputImageKey),
                           forKey: kCIInputImageKey)
    let compareRect = CGRect(x: 0, y: 0, width: CGFloat(leftImage.width), height: CGFloat(leftImage.height))
    
    let extents = CIVector(cgRect: compareRect)
    areaMaxFilter.setValue(extents, forKey: kCIInputExtentKey)
    
    // The filters have been setup, now set up the CGContext bitmap context the
    // output is drawn to. Setup the context with our supplied buffer.
    let alphaInfo = CGImageAlphaInfo.premultipliedLast
    let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    var buf: [CUnsignedChar] = Array<CUnsignedChar>(repeating: 255, count: 16)
    
    guard let context = CGContext(
        data: &buf,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 16,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        throw ImageDiffError.failedToCreateContext
    }
    
    // Now create the core image context CIContext from the bitmap context.
    let ciContextOpts = [
        CIContextOption.workingColorSpace : colorSpace,
        CIContextOption.useSoftwareRenderer : false
    ] as [CIContextOption : Any]
    let ciContext = CIContext(cgContext: context, options: ciContextOpts)
    
    // Get the output CIImage and draw that to the Core Image context.
    let valueImage = areaMaxFilter.value(forKey: kCIOutputImageKey)! as! CIImage
    ciContext.draw(valueImage, in: CGRect(x: 0, y: 0, width: 1, height: 1),
                   from: valueImage.extent)
    
    // This will have modified the contents of the buffer used for the CGContext.
    // Find the maximum value of the different color components. Remember that
    // the CGContext was created with a Premultiplied last meaning that alpha
    // is the fourth component with red, green and blue in the first three.
    let maxVal = max(buf[0], max(buf[1], buf[2]))
    let diff = Int(maxVal)
    
    return diff < 20
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
                    if try! compareImages(lastImageV, image) {
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
