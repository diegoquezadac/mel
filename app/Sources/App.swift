// Mel: a window to browse, read and play back meetings, plus a menu bar item for quick recording.
// It drives ./mel, so all recording and transcription logic stays in the scripts.
import AppKit
import AVFoundation
import SwiftUI

let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MelRoot") as? String ?? FileManager.default.currentDirectoryPath)
let recordingsDir = root.appendingPathComponent("recordings")
let serverLog = root.appendingPathComponent("server/server.log")
let serverConfig = root.appendingPathComponent("server/config.env") // read by ./mel when it starts the server
let voicesFile = root.appendingPathComponent("voices.json") // read by the client to recognize named voices

/// A named voiceprint: the average pyannote embedding over the meetings where you named this person.
struct Voice: Codable {
    var embedding: [Double]
    var meetings: Int
}

func unit(_ v: [Double]) -> [Double] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? v.map { $0 / norm } : v
}

struct ModelOption: Identifiable {
    let id: String // Hugging Face repo
    let name: String
}

let transcriptionModels = [
    ModelOption(id: "mlx-community/whisper-large-v3-turbo", name: "Whisper Large v3 Turbo · fast and accurate · 1.6 GB"),
    ModelOption(id: "mlx-community/whisper-large-v3-mlx", name: "Whisper Large v3 · most accurate, 2× slower · 3.1 GB"),
    ModelOption(id: "mlx-community/whisper-small-mlx", name: "Whisper Small · fastest, weaker Spanish · 0.5 GB"),
]

let titleModels = [
    ModelOption(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", name: "Qwen3 4B · balanced · 2.3 GB"),
    ModelOption(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5 7B · best titles, slower · 4.3 GB"),
    ModelOption(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B · 1.8 GB"),
    ModelOption(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", name: "Llama 3.2 1B · smallest · 0.7 GB"),
]

/// KEY=value lines of server/config.env.
func readServerConfig() -> [String: String] {
    let text = (try? String(contentsOf: serverConfig, encoding: .utf8)) ?? ""
    return Dictionary(text.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        return parts.count == 2 && !line.hasPrefix("#") ? (parts[0], parts[1]) : nil
    }, uniquingKeysWith: { $1 })
}

/// Languages the server detects among, as in server/app.py.
let configuredLanguages = (readServerConfig()["LANGUAGES"] ?? "en,es").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

/// Runs `./mel <args>`, reporting output lines and exit status on the main queue.
@discardableResult
func mel(_ args: [String], input: Pipe? = nil, onLine: @escaping (String) -> Void = { _ in }, onExit: @escaping (Int32) -> Void = { _ in }) -> Process {
    let process = Process()
    process.executableURL = root.appendingPathComponent("mel")
    process.arguments = args
    process.currentDirectoryURL = root
    var env = ProcessInfo.processInfo.environment
    // Apps launched from Finder get a minimal PATH; uv lives in Homebrew or ~/.local/bin.
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    env["PYTHONUNBUFFERED"] = "1"
    process.environment = env

    if let input { process.standardInput = input }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            DispatchQueue.main.async { onLine(line) }
        }
    }
    process.terminationHandler = { p in
        // Let the pipe drain its last lines before reporting the exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onExit(p.terminationStatus) }
    }
    do {
        try process.run()
    } catch {
        DispatchQueue.main.async {
            onLine("! could not run mel: \(error.localizedDescription)")
            onExit(-1)
        }
    }
    return process
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Same `hh:mm:ss` stamp the Python client writes into transcript.md.
func clock(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

struct Recording: Identifiable, Hashable {
    let url: URL
    let duration: TimeInterval
    let hasTranscript: Bool
    var id: String { url.path }
    /// Transcribed, even if nothing was said.
    var transcribed: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("transcript.json").path) }
    var folder: String { url.lastPathComponent }
    var audio: URL { url.appendingPathComponent("meeting.wav") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()

    /// Folders are named `<yyyy-MM-dd_HH-mm>[_label]`.
    var datePrefix: String { String(folder.prefix(16)) }
    var date: Date? { Self.stamp.date(from: datePrefix) }
    var label: String { folder.count > 17 ? String(folder.dropFirst(17)).replacingOccurrences(of: "-", with: " ") : "" }
    var title: String { label.isEmpty ? "Untitled meeting" : label }
}

/// One transcript line, as stored in transcript.json.
struct Entry: Codable, Identifiable {
    var start: Double
    var end: Double
    var speaker: String
    var language: String?
    var text: String
    var id: String { "\(start)|\(speaker)|\(text)" }
}

enum ServerState: Equatable {
    case stopped, starting, loading, ready, failed(String)
}

final class Model: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Model()
    static let live = "live"

    @Published var server = ServerState.stopped
    @Published var now = Date()
    @Published var recordings: [Recording] = []
    @Published var selection: String? {
        // Playback belongs to the meeting on screen.
        didSet { if player?.url?.deletingLastPathComponent().path != selection { stopPlayback() } }
    }
    var selectedRecording: Recording? { recordings.first { $0.id == selection } }
    @Published var transcribing: [String: String] = [:] // recording id → progress
    @Published var revision = 0 // bumped when transcripts change on disk
    @Published var voices: [String: Voice] = (try? Data(contentsOf: voicesFile)).flatMap { try? JSONDecoder().decode([String: Voice].self, from: $0) } ?? [:]

    // Recording
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" {
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            // Applies to the rest of a meeting in progress, too.
            recorderInput?.fileHandleForWriting.write(Data("language \(language)\n".utf8))
        }
    }
    @Published var floatingTranscript = UserDefaults.standard.object(forKey: "floatingTranscript") as? Bool ?? true {
        didSet { UserDefaults.standard.set(floatingTranscript, forKey: "floatingTranscript") }
    }
    @Published var mic = UserDefaults.standard.object(forKey: "mic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mic, forKey: "mic") }
    }
    @Published var transcriptionModel = UserDefaults.standard.string(forKey: "transcriptionModel") ?? transcriptionModels[0].id {
        didSet { modelsChanged(key: "transcriptionModel", value: transcriptionModel) }
    }
    @Published var titleModel = UserDefaults.standard.string(forKey: "titleModel") ?? titleModels[0].id {
        didSet { modelsChanged(key: "titleModel", value: titleModel) }
    }
    @Published var startedAt: Date?
    @Published var stopping = false
    @Published var folder: URL?
    @Published var status = ""
    @Published var liveEntries: [Entry] = []
    private var recorder: Process?
    private var recorderInput: Pipe?
    private var quitWhenStopped = false

    // Playback
    @Published var playing: URL?
    private var player: AVAudioPlayer?
    var playbackTime: Double { player?.currentTime ?? 0 }

    private var serverLaunched: Date?
    private var ticks = 0
    private let utterancePattern = #/^(?:\(\d+/\d+\) )?\[(\d\d):(\d\d):(\d\d)\] (Me|Them) \(\w+\): (.*)$/#
    private let progressPattern = #/^\((\d+)/(\d+)\)/#
    private let titledPattern = #/^Titled “(.*)” → (.*)$/# // the client renamed the meeting folder

    var isRecording: Bool { recorder != nil }

    override init() {
        super.init()
        refresh()
        for name in voices.keys { recognize(name) }  // apply names given in other meetings to earlier ones
        writeServerConfig()
        startServer()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        now = Date()
        ticks += 1
        if ticks % 2 == 0 { checkServer() }
        if ticks % 5 == 0 { refresh() }
    }

    // MARK: Server

    /// Updates the model choices and keeps everything else in the file (LANGUAGES, from `./mel setup`).
    private func writeServerConfig() {
        var lines = readServerConfig().filter { $0.key != "MODEL" && $0.key != "LLM" }.map { "\($0.key)=\($0.value)" }.sorted()
        lines += ["MODEL=\(transcriptionModel)", "LLM=\(titleModel)"]
        try? (lines.joined(separator: "\n") + "\n").write(to: serverConfig, atomically: true, encoding: .utf8)
    }

    private func modelsChanged(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: key)
        writeServerConfig()
        // A running server keeps its models; restart it unless a recording is using it (then the next start picks them up).
        guard !isRecording, server != .stopped else { return }
        serverLaunched = Date()
        server = .starting
        mel(["stop"], onExit: { _ in self.startServer() })
    }

    func startServer() {
        serverLaunched = Date()
        server = .starting
        mel(["server"])
    }

    func stopServer() {
        serverLaunched = nil
        mel(["stop"], onExit: { _ in self.checkServer() })
    }

    var serverText: String {
        switch server {
        case .ready: "Transcription ready"
        case .loading: "Loading model…"
        case .starting: "Starting…"
        case .stopped: "Transcription off"
        case let .failed(error): "Error: \(error)"
        }
    }

    var serverColor: Color {
        switch server {
        case .ready: .green
        case .loading, .starting: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    func checkServer() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/health")!)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let health = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                if let health {
                    if let error = health["error"] as? String {
                        self.server = .failed(error)
                    } else {
                        self.server = health["ready"] as? Bool == true ? .ready : .loading
                    }
                } else if let launched = self.serverLaunched, Date().timeIntervalSince(launched) < 60 {
                    self.server = .starting
                } else {
                    self.server = .stopped
                }
            }
        }.resume()
    }

    // MARK: Recording

    func startRecording() {
        liveEntries = []
        status = "Starting…"
        folder = nil
        var args = ["start", "--language", language]
        if !mic { args.append("--no-mic") }
        startedAt = Date()
        selection = Model.live
        if floatingTranscript { FloatingTranscript.shared.show() }
        recorderInput = Pipe()
        recorder = mel(args, input: recorderInput, onLine: handleRecorderLine, onExit: { code in
            FloatingTranscript.shared.hide()
            self.recorder = nil
            self.recorderInput = nil
            self.startedAt = nil
            self.stopping = false
            if code != 0, code != SIGTERM { self.status = "Recording exited with an error (code \(code)). \(self.status)" }
            self.refresh()
            if self.selection == Model.live, let folder = self.folder { self.selection = folder.path }
            if self.status.contains("no audio was captured") {
                self.selection = nil
                self.showCaptureFailure()
            }
            if self.quitWhenStopped { NSApp.terminate(nil) }
        })
    }

    /// Without Screen & System Audio Recording permission, ScreenCaptureKit delivers nothing.
    private func showCaptureFailure() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Mel couldn't hear anything"
        alert.informativeText = "Allow Mel under Screen & System Audio Recording and under Microphone in System Settings › Privacy & Security, then quit and reopen Mel."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Stops capturing; the transcript is then finished, speakers detected and the meeting named.
    func stopRecording() {
        guard !stopping else { return }  // a double click must not skip anything
        recorder?.terminate()
        status = "Stopping…"
        stopping = true
    }

    /// Skips the step that is running after stopping (pending transcription, speakers or naming); files are still saved.
    func skipPending() {
        if stopping { recorder?.terminate() }
    }

    private func handleRecorderLine(_ line: String) {
        if let m = line.wholeMatch(of: utterancePattern) {
            let start = Double(Int(m.1)! * 3600 + Int(m.2)! * 60 + Int(m.3)!)
            liveEntries.append(Entry(start: start, end: start, speaker: String(m.4), text: String(m.5)))
        } else if let m = line.wholeMatch(of: titledPattern) {
            folder = URL(fileURLWithPath: String(m.2)).standardizedFileURL
            status = "Titled “\(m.1)”"
        } else if line.hasPrefix("Language: ") {
            return
        } else if line.hasPrefix("● Recording → ") {
            folder = URL(fileURLWithPath: String(line.dropFirst("● Recording → ".count))).standardizedFileURL
            status = "Listening"
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.contains("Ctrl+C"), !line.hasPrefix("[") {  // [capture] lines are diagnostics
            status = line.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Recordings

    func refresh() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        recordings = folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let wav = ["meeting.wav", "mic.wav", "system.wav"].map { url.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                let bytes = wav.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 44
                let transcript = url.appendingPathComponent("transcript.md")
                let hasText = (try? String(contentsOf: transcript, encoding: .utf8))?.contains("**") ?? false
                return Recording(url: url, duration: Double(bytes - 44) / 32_000, hasTranscript: hasText)
            }
    }

    /// Past recordings grouped by day, newest first. The one being recorded is shown separately.
    var days: [(day: Date, recordings: [Recording])] {
        let visible = recordings.filter { !(isRecording && $0.url == folder) }
        let groups = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
        return groups.sorted { $0.key > $1.key }.map { (day: $0.key, recordings: $0.value) }
    }

    /// `language` defaults to the one chosen for new recordings.
    func transcribe(_ recording: Recording, language: String? = nil) {
        var id = recording.id // changes if the meeting gets titled (its folder is renamed)
        transcribing[id] = "Starting…"
        mel(["transcribe", recording.url.path, "--language", language ?? self.language], onLine: { line in
            if let match = line.prefixMatch(of: self.progressPattern) {
                self.transcribing[id] = "Transcribing \(match.1)/\(match.2)"
            } else if line.hasPrefix("Detecting speakers") {
                self.transcribing[id] = "Detecting speakers…"
            } else if line.hasPrefix("Naming meeting") {
                self.transcribing[id] = "Naming meeting…"
            } else if line.contains("loading model") {
                self.transcribing[id] = "Loading model…"
            } else if let m = line.wholeMatch(of: self.titledPattern) {
                let renamed = URL(fileURLWithPath: String(m.2)).standardizedFileURL.path
                self.transcribing[id] = nil
                if self.selection == id { self.selection = renamed }
                id = renamed
                self.transcribing[id] = "Finishing…"
                self.refresh()
            }
        }, onExit: { _ in
            self.transcribing[id] = nil
            self.refresh()
            self.revision += 1
        })
    }

    func entries(for recording: Recording) -> [Entry] {
        let data = try? Data(contentsOf: recording.url.appendingPathComponent("transcript.json"))
        return data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Writes transcript.json and transcript.md in the same format as the Python client.
    private func save(_ entries: [Entry], in folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? encoder.encode(entries).write(to: folder.appendingPathComponent("transcript.json"))
        let body = entries.map { "[\(clock($0.start))] **\($0.speaker)**: \($0.text)" }.joined(separator: "\n\n")
        try? "# \(folder.lastPathComponent)\n\n\(body)\n".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    func renameSpeaker(in recording: Recording, from old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        var entries = entries(for: recording)
        for i in entries.indices where entries[i].speaker == old { entries[i].speaker = new }
        save(entries, in: recording.url)
        // Remember this voice under the new name so future meetings recognize it.
        let printsFile = recording.url.appendingPathComponent("speakers.json")
        if var prints = (try? Data(contentsOf: printsFile)).flatMap({ try? JSONDecoder().decode([String: [Double]].self, from: $0) }),
           let voiceprint = prints.removeValue(forKey: old) {
            prints[new] = voiceprint
            try? JSONEncoder().encode(prints).write(to: printsFile)
            learnVoice(new, from: voiceprint)
            recognize(new, except: recording)
        }
        revision += 1
    }

    /// Names this voice in earlier meetings too: an unnamed speaker ("Speaker N") whose voiceprint
    /// matches gets the name, without transcribing again. Same threshold as the client (VOICE_MATCH).
    private func recognize(_ name: String, except current: Recording? = nil) {
        guard let voice = voices[name] else { return }
        for recording in recordings where recording.id != current?.id {
            let printsFile = recording.url.appendingPathComponent("speakers.json")
            guard var prints = (try? Data(contentsOf: printsFile)).flatMap({ try? JSONDecoder().decode([String: [Double]].self, from: $0) }),
                  prints[name] == nil else { continue }
            let match = prints
                .filter { $0.key.wholeMatch(of: #/Speaker \d+/#) != nil && $0.value.count == voice.embedding.count }
                .map { (speaker: $0.key, score: zip(unit($0.value), voice.embedding).reduce(0) { $0 + $1.0 * $1.1 }) }
                .max { $0.score < $1.score }
            guard let match, match.score >= 0.75 else { continue }
            var entries = entries(for: recording)
            for i in entries.indices where entries[i].speaker == match.speaker { entries[i].speaker = name }
            save(entries, in: recording.url)
            prints[name] = prints.removeValue(forKey: match.speaker)
            try? JSONEncoder().encode(prints).write(to: printsFile)
        }
    }

    private func learnVoice(_ name: String, from voiceprint: [Double]) {
        let sample = unit(voiceprint)
        if var voice = voices[name], voice.embedding.count == sample.count {
            let n = Double(voice.meetings)
            voice.embedding = unit(zip(voice.embedding, sample).map { ($0 * n + $1) / (n + 1) })
            voice.meetings += 1
            voices[name] = voice
        } else {
            voices[name] = Voice(embedding: sample, meetings: 1)
        }
        saveVoices()
    }

    func forgetVoice(_ name: String) {
        voices[name] = nil
        saveVoices()
    }

    private func saveVoices() {
        try? JSONEncoder().encode(voices).write(to: voicesFile)
    }

    func trash(_ recording: Recording) {
        if playing?.deletingLastPathComponent() == recording.url { stopPlayback() }
        try? FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        if selection == recording.id { selection = nil }
        refresh()
    }

    func rename(_ recording: Recording, to title: String) {
        let slug = title.trimmingCharacters(in: .whitespaces).replacing(#/[\s/:]+/#, with: "-")
        let name = slug.isEmpty ? recording.datePrefix : "\(recording.datePrefix)_\(slug)"
        let destination = recordingsDir.appendingPathComponent(name).standardizedFileURL
        guard name != recording.folder, !FileManager.default.fileExists(atPath: destination.path) else { return }
        guard (try? FileManager.default.moveItem(at: recording.url, to: destination)) != nil else { return }
        if recording.hasTranscript { // the transcript heading carries the folder name
            save(entries(for: Recording(url: destination, duration: 0, hasTranscript: true)), in: destination)
        }
        if playing?.deletingLastPathComponent() == recording.url { stopPlayback() }
        refresh()
        selection = destination.path
    }

    // MARK: Playback

    func play(_ file: URL, from time: Double) {
        if player?.url != file {
            player = try? AVAudioPlayer(contentsOf: file)
            player?.delegate = self
        }
        guard let player else { return }
        player.currentTime = time
        player.play()
        playing = file
    }

    func togglePlayback(_ file: URL) {
        if playing == file, player?.isPlaying == true {
            player?.pause()
            playing = nil
        } else {
            play(file, from: player != nil && player?.url == file ? playbackTime : 0)
        }
    }

    func skip(by seconds: Double) {
        guard let recording = selectedRecording else { return }
        seek(recording.audio, to: min(max(position(of: recording.audio) + seconds, 0), recording.duration))
    }

    /// Moves the playhead; keeps playing if it was.
    func seek(_ file: URL, to time: Double) {
        if playing == file { return play(file, from: time) }
        if player?.url != file {
            player = try? AVAudioPlayer(contentsOf: file)
            player?.delegate = self
        }
        player?.currentTime = time
        objectWillChange.send()
    }

    func position(of file: URL) -> Double {
        player?.url == file ? playbackTime : 0
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = nil
    }

    func quit() {
        guard isRecording else { return NSApp.terminate(nil) }
        quitWhenStopped = true
        stopRecording()
    }
}

/// A small always-on-top panel with the live transcript, so you can follow the meeting from any app.
final class FloatingTranscript {
    static let shared = FloatingTranscript()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = .clear
            panel.contentView = NSHostingView(rootView: FloatingTranscriptView().environmentObject(Model.shared))
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 320, y: screen.minY + 20))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Esc stops the recording. Space plays or pauses (or stops the recording on its page) and ←/→ skip 15 seconds, as in Voice Memos, unless you are typing.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let model = Model.shared
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true,  // selected transcript text still plays
                  NSApp.keyWindow?.identifier?.rawValue.contains("Settings") != true else { return event }
            if model.isRecording, event.keyCode == 53 || (event.keyCode == 49 && model.selection == Model.live) {  // Esc, or Space on the recording page
                model.stopRecording()
                return nil
            }
            guard let recording = model.selectedRecording else { return event }
            switch event.keyCode {
            case 49: model.togglePlayback(recording.audio)
            case 123: model.skip(by: -15)
            case 124: model.skip(by: 15)
            default: return event
            }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Free the GPU memory held by the models, unless a recording or transcription started
        // from the terminal is still using the server.
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        busy.arguments = ["-f", "client/mel.py"]
        try? busy.run()
        busy.waitUntilExit()
        if busy.terminationStatus != 0 { mel(["stop"]).waitUntilExit() }
    }
}

@main
struct MeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model.shared

    var body: some Scene {
        Window("Mel", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 940, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { model.startRecording() }
                    .keyboardShortcut("r")
                    .disabled(model.isRecording)
                Button("Stop Recording") { model.stopRecording() }
                    .keyboardShortcut(".")
                    .disabled(!model.isRecording)
            }
            CommandMenu("Meeting") {
                MeetingCommands().environmentObject(model)
            }
            CommandGroup(after: .windowList) {
                Button("Show Floating Transcript") { FloatingTranscript.shared.show() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!model.isRecording)
            }
        }

        MenuBarExtra {
            MenuBarMenu().environmentObject(model)
        } label: {
            if let started = model.startedAt {
                Image(systemName: "record.circle.fill")
                Text(formatDuration(model.now.timeIntervalSince(started)))
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
