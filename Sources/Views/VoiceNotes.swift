import AVFoundation
import SwiftUI

/// Plays one recording at a time; pages listen for changes to update their play buttons.
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    static let changed = Notification.Name("VoicePlayerChanged")

    private var player: AVAudioPlayer?
    private(set) var playing: URL?

    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playing = url
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func stop() {
        player?.stop()
        player = nil
        guard playing != nil else { return }
        playing = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}

/// What a finished recording becomes.
enum VoicePurpose: Identifiable {
    case note
    /// Linked to handwriting or text in this area.
    case link(CGRect)

    var id: String {
        switch self {
        case .note: "note"
        case .link(let area): "link-\(area.minX)-\(area.minY)"
        }
    }
}

/// Records into a temporary file; Save hands back the file and its length.
@Observable
final class VoiceRecorder: NSObject {
    private(set) var recording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var denied = false
    private(set) var file: URL?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?

    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.denied = true
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else { return }
        self.recorder = recorder
        file = url
        recording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.elapsed = self?.recorder?.currentTime ?? 0
        }
    }

    func stop() {
        if let recorder { elapsed = recorder.currentTime }
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recording = false
    }
}

struct VoiceRecorderSheet: View {
    let onSave: (URL, TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()

    var body: some View {
        VStack(spacing: 22) {
            Text("Voice Note")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(Self.clock(recorder.elapsed))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(recorder.recording ? Theme.accent : Theme.ink)
            if recorder.denied {
                Text("Inkwell needs microphone access. Turn it on in Settings.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            Button {
                recorder.recording ? recorder.stop() : recorder.start()
            } label: {
                Image(systemName: recorder.recording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(recorder.recording ? Theme.accent : .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.recording ? "Stop" : "Record")
            HStack(spacing: 12) {
                Button("Cancel") {
                    recorder.stop()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Add to Page") {
                    recorder.stop()
                    if let file = recorder.file, recorder.elapsed > 0.3 { onSave(file, recorder.elapsed) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.file == nil || recorder.recording)
            }
        }
        .padding(30)
        .frame(minWidth: 320)
        .presentationDetents([.height(360)])
        .onDisappear { recorder.stop() }
    }

    static func clock(_ time: TimeInterval) -> String {
        let seconds = Int(time.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
