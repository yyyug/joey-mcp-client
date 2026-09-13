import Flutter
import UIKit
import AVFoundation

class SpeechChannelHandler: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    private var result: FlutterResult?
    private var isSpeaking: Bool {
        return synthesizer?.isSpeaking ?? false
    }

    func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "speak":
            if let text = call.arguments as? String {
                speak(text: text, result: result)
            } else {
                result(FlutterError(code: "invalid_argument", message: "Text required", details: nil))
            }
        case "stop":
            stopSpeaking()
            result(true)
        case "pause":
            pauseSpeaking()
            result(true)
        case "resume":
            resumeSpeaking()
            result(true)
        case "isSpeaking":
            result(isSpeaking)
        case "getAvailableVoices":
            result(getAvailableVoices())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func speak(text: String, result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("SpeechChannelHandler: Failed to set audio session category: \(error)")
            }

            if self.synthesizer == nil {
                self.synthesizer = AVSpeechSynthesizer()
                self.synthesizer?.delegate = self
            }

            // Stop any current speech
            if self.synthesizer?.isSpeaking == true {
                self.synthesizer?.stopSpeaking(at: .immediate)
            }

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0

            self.synthesizer?.speak(utterance)
            result(true)
        }
    }

    private func stopSpeaking() {
        DispatchQueue.main.async { [weak self] in
            if self?.synthesizer?.isSpeaking == true {
                self?.synthesizer?.stopSpeaking(at: .immediate)
            }
        }
    }

    private func pauseSpeaking() {
        DispatchQueue.main.async { [weak self] in
            if self?.synthesizer?.isSpeaking == true {
                self?.synthesizer?.pauseSpeaking(at: .immediate)
            }
        }
    }

    private func resumeSpeaking() {
        DispatchQueue.main.async { [weak self] in
            if self?.synthesizer?.isPaused == true {
                self?.synthesizer?.continueSpeaking()
            }
        }
    }

    private func getAvailableVoices() -> [[String: String]] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { voice in
                [
                    "identifier": voice.identifier,
                    "name": voice.name,
                    "language": voice.language,
                    "quality": voice.quality == .enhanced ? "enhanced" : "default"
                ]
            }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // Could send event to Flutter here
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Could send event to Flutter here
    }
}
