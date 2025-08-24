import Flutter
import UIKit
import ShazamKit
import AVFoundation

public class SwiftFlutterShazamKitPlugin: NSObject, FlutterPlugin {
    private var session: SHSession?
    private let audioEngine = AVAudioEngine()
    private let mixerNode = AVAudioMixerNode()
    private var callbackChannel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_shazam_kit",
            binaryMessenger: registrar.messenger()
        )
        let instance = SwiftFlutterShazamKitPlugin(
            callbackChannel: FlutterMethodChannel(
                name: "flutter_shazam_kit_callback",
                binaryMessenger: registrar.messenger()
            )
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(callbackChannel: FlutterMethodChannel? = nil) {
        self.callbackChannel = callbackChannel
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configureShazamKitSession":
            configureShazamKitSession()
            result(nil)

        case "startDetectionWithMicrophone":
            do {
                try configureAudio()
                try startListening(result: result)
            } catch {
                callbackChannel?.invokeMethod("didHasError", arguments: error.localizedDescription)
            }

        case "endDetectionWithMicrophone":
            stopListening()
            result(nil)

        case "endSession":
            session = nil
            stopListening()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - ShazamKit Session
extension SwiftFlutterShazamKitPlugin {
    func configureShazamKitSession() {
        if session == nil {
            session = SHSession()
            session?.delegate = self
        }
    }

    func addAudio(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        session?.matchStreamingBuffer(buffer, at: audioTime)
    }
}

// MARK: - Audio Engine Setup
extension SwiftFlutterShazamKitPlugin {
    func configureAudio() throws {
        let audioSession = AVAudioSession.sharedInstance()

        try audioSession.setCategory(.playAndRecord,
                                     mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)

        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)

        audioEngine.attach(mixerNode)
        audioEngine.connect(audioEngine.inputNode, to: mixerNode, format: inputFormat)

        // Install tap to capture mic audio → ShazamKit
        mixerNode.installTap(onBus: 0, bufferSize: 8192, format: outputFormat) { buffer, audioTime in
            self.addAudio(buffer: buffer, audioTime: audioTime)
        }
    }

    func startListening(result: FlutterResult) throws {
        guard session != nil else {
            callbackChannel?.invokeMethod("didHasError",
                                          arguments: "ShazamSession not found, call configureShazamKitSession() first.")
            result(nil)
            return
        }

        guard !audioEngine.isRunning else {
            callbackChannel?.invokeMethod("didHasError",
                                          arguments: "Audio engine already running, stop it first.")
            return
        }

        callbackChannel?.invokeMethod("detectStateChanged", arguments: 1)

        let audioSession = AVAudioSession.sharedInstance()
        audioSession.requestRecordPermission { [weak self] success in
            guard let self = self else { return }

            if !success {
                self.callbackChannel?.invokeMethod("didHasError",
                                                   arguments: "Microphone permission denied. Enable it in settings.")
                return
            }

            DispatchQueue.main.async {
                do {
                    try self.audioEngine.start()
                } catch {
                    self.callbackChannel?.invokeMethod("didHasError",
                                                       arguments: "Failed to start audio engine.")
                }
            }
        }
        result(nil)
    }

    func stopListening() {
        if audioEngine.isRunning {
            mixerNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            try? AVAudioSession.sharedInstance().setActive(false)
        }
        callbackChannel?.invokeMethod("detectStateChanged", arguments: 0)
    }
}

// MARK: - ShazamKit Delegate
extension SwiftFlutterShazamKitPlugin: SHSessionDelegate {
    public func session(_ session: SHSession, didFind match: SHMatch) {
        var mediaItems: [[String: Any]] = []

        match.mediaItems.forEach { rawItem in
            var item: [String: Any] = [:]
            item["title"] = rawItem.title
            item["subtitle"] = rawItem.subtitle
            item["shazamId"] = rawItem.shazamID
            item["appleMusicId"] = rawItem.appleMusicID
            if let appleUrl = rawItem.appleMusicURL { item["appleMusicUrl"] = appleUrl.absoluteString }
            if let artworkUrl = rawItem.artworkURL { item["artworkUrl"] = artworkUrl.absoluteString }
            item["artist"] = rawItem.artist
            item["matchOffset"] = rawItem.matchOffset
            if let videoUrl = rawItem.videoURL { item["videoUrl"] = videoUrl.absoluteString }
            if let webUrl = rawItem.webURL { item["webUrl"] = webUrl.absoluteString }
            item["genres"] = rawItem.genres
            item["isrc"] = rawItem.isrc
            mediaItems.append(item)
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: mediaItems)
            let jsonString = String(data: jsonData, encoding: .utf8)
            self.callbackChannel?.invokeMethod("matchFound", arguments: jsonString)
        } catch {
            callbackChannel?.invokeMethod("didHasError",
                                          arguments: "Error formatting Shazam data.")
        }
    }

    public func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        if let error = error {
            callbackChannel?.invokeMethod("didHasError", arguments: error.localizedDescription)
        } else {
            callbackChannel?.invokeMethod("notFound", arguments: nil)
        }
    }
}
