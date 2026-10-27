// Mel: a window to browse, read and play back meetings, plus a menu bar item for quick recording.
// It drives ./mel, so all recording and transcription logic stays in the scripts.
import AppKit
import AVFoundation
import SwiftUI

let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MelRoot") as? String ?? FileManager.default.currentDirectoryPath)
/// mel.db and Recordings/: MEL_DATA when set (development), else where ./mel build put them, else the default.
let dataDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEL_DATA"]
    ?? Bundle.main.object(forInfoDictionaryKey: "MelData") as? String
    ?? NSHomeDirectory() + "/Library/Application Support/Mel")
let recordingsDir = dataDir.appendingPathComponent("Recordings")
let serverLog = root.appendingPathComponent("server/server.log")

/// Someone you've named, as listed in Settings › Voices.
struct Voice {
    let id: Int64
    let meetings: Int
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

/// Languages the server detects among (settings.languages, set by `./mel setup`).
var configuredLanguages: [String] {
    (Database.shared.setting("languages") ?? "en,es").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

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

/// A row of `meetings`.
struct Recording: Identifiable, Hashable {
    let meeting: Int64
    let label: String // the title, empty until named
    let date: Date?
    let duration: TimeInterval
    let folder: String
    let status: String
    let segments: Int
    var id: String { String(meeting) }
    var title: String { label.isEmpty ? "Untitled meeting" : label }
    var hasTranscript: Bool { segments > 0 }
    /// Transcribed, even if nothing was said.
    var transcribed: Bool { status == "done" }
    var url: URL { recordingsDir.appendingPathComponent(folder) }
    var audio: URL { url.appendingPathComponent("meeting.wav") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    init(_ row: Row) {
        meeting = row["id"] as! Int64
        label = row["title"] as? String ?? ""
        date = (row["started_at"] as? String).flatMap(Self.stamp.date(from:))
        duration = row["duration"] as? Double ?? 0
        folder = row["folder"] as? String ?? ""
        status = row["status"] as? String ?? "done"
        segments = Int(row["segments"] as? Int64 ?? 0)
    }
}

/// A row of `segments`, with its speaker's name: the linked person's, or the speaker's label.
struct Entry: Identifiable {
    var id: Int64
    var start: Double
    var end: Double
    var speaker: String
    var speakerId: Int64
    var language: String?
    var text: String
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
    @Published var revision = 0 // bumped when transcripts change in the database
    @Published var voices: [String: Voice] = [:]

    // Settings, stored in the database's settings table
    @Published var language = "auto" {
        didSet {
            guard loaded else { return }
            db.setSetting("language", language)
            // Applies to the rest of a meeting in progress, too.
            recorderInput?.fileHandleForWriting.write(Data("language \(language)\n".utf8))
        }
    }
    @Published var floatingTranscript = true {
        didSet { if loaded { db.setSetting("floating_transcript", floatingTranscript ? "1" : "0") } }
    }
    @Published var mic = true {
        didSet { if loaded { db.setSetting("mic", mic ? "1" : "0") } }
    }
    @Published var transcriptionModel = transcriptionModels[0].id {
        didSet { modelsChanged(key: "model", value: transcriptionModel, old: oldValue) }
    }
    @Published var titleModel = titleModels[0].id {
        didSet { modelsChanged(key: "llm", value: titleModel, old: oldValue) }
    }

    // Recording
    @Published var startedAt: Date?
    @Published var stopping = false
    @Published var liveMeeting: Int64?
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
    private var loaded = false // settings read from the database; their didSet must not write them back yet
    private var db: Database { .shared } // opened on first use, after ./mel init created it
    private let progressPattern = #/^\((\d+)/(\d+)\)/#
    private let titledPattern = #/^Titled “(.*)”$/#
    private let recordingPattern = #/^● Recording → meeting (\d+)/#

    var isRecording: Bool { recorder != nil }

    override init() {
        // ./mel creates the database and applies migrations; wait for it before the first query.
        mel(["init"]).waitUntilExit()
        super.init()
        language = db.setting("language") ?? "auto"
        floatingTranscript = db.setting("floating_transcript") != "0"
        mic = db.setting("mic") != "0"
        transcriptionModel = db.setting("model") ?? transcriptionModels[0].id
        titleModel = db.setting("llm") ?? titleModels[0].id
        loaded = true
        refresh()
        for voice in voices.values { recognize(voice.id) }  // apply names given in other meetings to earlier ones
        startServer()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        now = Date()
        ticks += 1
        if ticks % 2 == 0 { checkServer() }
        // A recording or re-transcription writes from another process; re-read when it commits.
        if db.changed() {
            refresh()
            if let liveMeeting { liveEntries = entries(for: liveMeeting) }
        }
    }

    // MARK: Server

    private func modelsChanged(key: String, value: String, old: String) {
        guard loaded, value != old else { return }
        db.setSetting(key, value)
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
        liveMeeting = nil
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
            if self.selection == Model.live, let meeting = self.liveMeeting { self.selection = String(meeting) }
            self.liveMeeting = nil
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
        if let m = line.prefixMatch(of: recordingPattern) {
            liveMeeting = Int64(m.1)
            status = "Listening"
        } else if let m = line.wholeMatch(of: titledPattern) {
            status = "Titled “\(m.1)”"
        } else if line.hasPrefix("Language: ") || line.hasPrefix("[") { // utterances come from the database; [capture] lines are diagnostics
            return
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.contains("Ctrl+C") {
            status = line.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Meetings

    func refresh() {
        recordings = db.query("""
            SELECT m.*, (SELECT count(*) FROM segments s WHERE s.meeting_id = m.id) AS segments
            FROM meetings m ORDER BY m.started_at DESC
            """).map(Recording.init)
        voices = Dictionary(uniqueKeysWithValues: db.query("SELECT id, name, meetings FROM people").map {
            ($0["name"] as! String, Voice(id: $0["id"] as! Int64, meetings: Int($0["meetings"] as? Int64 ?? 1)))
        })
    }

    /// Past meetings grouped by day, newest first. The one being recorded is shown separately.
    var days: [(day: Date, recordings: [Recording])] {
        let visible = recordings.filter { !(isRecording && $0.meeting == liveMeeting) }
        let groups = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
        return groups.sorted { $0.key > $1.key }.map { (day: $0.key, recordings: $0.value) }
    }

    /// `language` defaults to the one chosen for new recordings.
    func transcribe(_ recording: Recording, language: String? = nil) {
        let id = recording.id
        transcribing[id] = "Starting…"
        mel(["transcribe", id, "--language", language ?? self.language], onLine: { line in
            if let match = line.prefixMatch(of: self.progressPattern) {
                self.transcribing[id] = "Transcribing \(match.1)/\(match.2)"
            } else if line.hasPrefix("Detecting speakers") {
                self.transcribing[id] = "Detecting speakers…"
            } else if line.hasPrefix("Naming meeting") {
                self.transcribing[id] = "Naming meeting…"
            } else if line.contains("loading model") {
                self.transcribing[id] = "Loading model…"
            }
        }, onExit: { _ in
            self.transcribing[id] = nil
            self.refresh()
            self.revision += 1
        })
    }

    func entries(for meeting: Int64) -> [Entry] {
        db.query("""
            SELECT s.id, s.start, s.end, s.language, s.text, s.speaker_id, COALESCE(p.name, sp.label) AS speaker
            FROM segments s JOIN speakers sp ON sp.id = s.speaker_id LEFT JOIN people p ON p.id = sp.person_id
            WHERE s.meeting_id = ? ORDER BY s.start
            """, meeting).map {
            Entry(id: $0["id"] as! Int64, start: $0["start"] as? Double ?? 0, end: $0["end"] as? Double ?? 0,
                  speaker: $0["speaker"] as? String ?? "", speakerId: $0["speaker_id"] as! Int64,
                  language: $0["language"] as? String, text: $0["text"] as? String ?? "")
        }
    }

    func entries(for recording: Recording) -> [Entry] { entries(for: recording.meeting) }

    /// Naming a speaker who has a voiceprint links them to that person (created if new), teaches Mel the
    /// voice and looks for it in other meetings. "Me" and "Them" have no voiceprint and are just relabeled.
    func renameSpeaker(in recording: Recording, from old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        let speakers = db.query("""
            SELECT s.id, s.voiceprint FROM speakers s LEFT JOIN people p ON p.id = s.person_id
            WHERE s.meeting_id = ? AND COALESCE(p.name, s.label) = ?
            """, recording.meeting, old)
        var learned: Set<Int64> = []
        db.transaction {
            for speaker in speakers {
                if let voiceprint = speaker["voiceprint"] as? Data {
                    let person = learnVoice(new, from: voiceprint)
                    db.execute("UPDATE speakers SET person_id = ? WHERE id = ?", person, speaker["id"])
                    learned.insert(person)
                } else {
                    db.execute("UPDATE OR IGNORE speakers SET label = ?, person_id = NULL WHERE id = ?", new, speaker["id"])
                }
            }
        }
        for person in learned { recognize(person, except: recording.meeting) }
        refresh()
        revision += 1
    }

    /// Names this person in other meetings too: in each meeting where they aren't yet, the unnamed speaker
    /// ("Speaker N") whose voiceprint matches best gets linked. Same threshold as the client (VOICE_MATCH).
    private func recognize(_ person: Int64, except current: Int64? = nil) {
        guard let blob = db.query("SELECT voiceprint FROM people WHERE id = ?", person).first?["voiceprint"] as? Data else { return }
        let voice = floats(blob)
        let candidates = db.query("""
            SELECT id, meeting_id, voiceprint FROM speakers
            WHERE person_id IS NULL AND voiceprint IS NOT NULL AND label LIKE 'Speaker %' AND meeting_id != ?
              AND meeting_id NOT IN (SELECT meeting_id FROM speakers WHERE person_id = ?)
            """, current ?? -1, person)
        let best = Dictionary(grouping: candidates) { $0["meeting_id"] as! Int64 }.compactMap { _, speakers in
            speakers.map { (id: $0["id"] as! Int64, score: zip(floats($0["voiceprint"] as! Data), voice).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
                .max { $0.score < $1.score }
        }
        for match in best where match.score >= 0.75 {
            db.execute("UPDATE speakers SET person_id = ? WHERE id = ?", person, match.id)
        }
    }

    /// Adds a voiceprint to the person's running mean, creating them if needed. Returns their id.
    private func learnVoice(_ name: String, from voiceprint: Data) -> Int64 {
        let sample = unit(floats(voiceprint))
        if let person = db.query("SELECT id, voiceprint, meetings FROM people WHERE name = ?", name).first {
            let n = Float(person["meetings"] as? Int64 ?? 1)
            let mean = unit(zip(floats(person["voiceprint"] as! Data), sample).map { ($0 * n + $1) / (n + 1) })
            db.execute("UPDATE people SET voiceprint = ?, meetings = meetings + 1 WHERE id = ?", blob(mean), person["id"])
            return person["id"] as! Int64
        }
        return db.execute("INSERT INTO people (name, voiceprint) VALUES (?, ?)", name, blob(sample))
    }

    /// Mel stops recognizing them; meetings keep showing their name as the speaker's label.
    func forgetVoice(_ name: String) {
        guard let voice = voices[name] else { return }
        db.transaction {
            db.execute("UPDATE OR IGNORE speakers SET label = ? WHERE person_id = ? AND label LIKE 'Speaker %'", name, voice.id)
            db.execute("DELETE FROM people WHERE id = ?", voice.id)
        }
        refresh()
        revision += 1
    }

    func trash(_ recording: Recording) {
        if playing?.deletingLastPathComponent() == recording.url { stopPlayback() }
        try? FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        db.execute("DELETE FROM meetings WHERE id = ?", recording.meeting)
        if selection == recording.id { selection = nil }
        refresh()
    }

    func rename(_ recording: Recording, to title: String) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard title != recording.label else { return }
        db.execute("UPDATE meetings SET title = ? WHERE id = ?", title.isEmpty ? nil : title, recording.meeting)
        refresh()
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
