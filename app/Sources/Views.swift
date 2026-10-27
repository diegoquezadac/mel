import AppKit
import SwiftUI

/// Stable colors per meeting: you get the system accent color, others standard system colors in order of appearance.
func speakerColors(_ entries: [Entry]) -> [String: Color] {
    let palette: [Color] = [.orange, .purple, .pink, .teal, .indigo, .green, .yellow, .mint]
    var colors: [String: Color] = [:]
    var next = 0
    for speaker in entries.map(\.speaker) where colors[speaker] == nil {
        if speaker == "Me" {
            colors[speaker] = .accentColor
        } else {
            colors[speaker] = palette[next % palette.count]
            next += 1
        }
    }
    return colors
}

struct MainView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                if model.selection == Model.live, model.isRecording {
                    LiveView()
                } else if let recording = model.recordings.first(where: { $0.id == model.selection }) {
                    MeetingView(recording: recording).id(recording.id)
                } else {
                    EmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .toolbar(removing: .title)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        List(selection: $model.selection) {
            if model.isRecording {
                Section("Now") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New Recording")
                        Text(model.stopping ? "Finishing…" : "Recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Model.live)
                }
            }
            ForEach(model.days, id: \.day) { group in
                Section(dayTitle(group.day)) {
                    ForEach(group.recordings) { MeetingRow(recording: $0).tag($0.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let recording = model.selectedRecording { model.trash(recording) } }
        .overlay {
            if model.recordings.isEmpty, !model.isRecording {
                Text("No Meetings").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRecording {
                    // Red only while recording, like the system's recording indicator.
                    Button {
                        model.stopRecording()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text(formatDuration(model.now.timeIntervalSince(model.startedAt ?? model.now))).monospacedDigit()
                        }
                        .foregroundStyle(.red)
                    }
                    .disabled(model.stopping)
                    .help("Stop recording (Esc)")
                } else {
                    Button {
                        model.startRecording()
                    } label: {
                        Label("New Recording", systemImage: "plus")
                    }
                    .help("New recording (⌘R)")
                }
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if day == .distantPast { return "Older" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// Auto-detect plus each configured language (LANGUAGES in server/config.env, set by `./mel setup`), named in itself.
let languages: [(String, String)] = {
    let codes = configuredLanguages
    let name = { (code: String) in Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: code)) ?? code }
    let auto = codes.count > 1 ? "Auto-detect (\(codes.map(name).joined(separator: ", ")))" : "Auto-detect"
    return [("auto", auto)] + codes.map { ($0, name($0)) }
}()

struct LanguageOptions: View {
    var body: some View {
        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
    }
}

/// One menu item per language, for transcribing a saved meeting again.
struct TranscribeOptions: View {
    @EnvironmentObject var model: Model
    let recording: Recording

    var body: some View {
        ForEach(languages, id: \.0) { code, name in
            Button(name) { model.transcribe(recording, language: code) }
        }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var model: Model
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title)
                .foregroundStyle(recording.label.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            HStack(spacing: 4) {
                if let date = recording.date { Text(date.formatted(date: .omitted, time: .shortened)) }
                Text("·")
                Text(formatDuration(recording.duration))
                if let progress = model.transcribing[recording.id] {
                    Text("· \(progress)")
                } else if !recording.hasTranscript {
                    Text(recording.transcribed ? "· No speech" : "· No transcript")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contextMenu {
            Menu(recording.hasTranscript ? "Transcribe Again" : "Transcribe") { TranscribeOptions(recording: recording) }
                .disabled(model.transcribing[recording.id] != nil)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
            Divider()
            Button("Move to Trash") { model.trash(recording) }
        }
    }
}

/// The Meeting menu: everything on the meeting page, with its keyboard shortcuts.
struct MeetingCommands: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let recording = model.selectedRecording
        Button(recording.map { model.playing == $0.audio } == true ? "Pause (Space)" : "Play (Space)") {
            if let recording { model.togglePlayback(recording.audio) }
        }
        .disabled(recording == nil)
        Button("Skip Back 15 Seconds (←)") { model.skip(by: -15) }
            .disabled(recording == nil)
        Button("Skip Forward 15 Seconds (→)") { model.skip(by: 15) }
            .disabled(recording == nil)
        Divider()
        Menu("Transcribe Again") {
            if let recording { TranscribeOptions(recording: recording) }
        }
        .disabled(recording == nil || model.transcribing[recording!.id] != nil)
        Button("Copy Transcript") {
            guard let recording else { return }
            let entries = model.entries(for: recording)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entries.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n"), forType: .string)
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(recording?.hasTranscript != true)
        Button("Show in Finder") {
            if let recording { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(recording == nil)
        Divider()
        Button("Move to Trash (⌫)") {
            if let recording { model.trash(recording) }
        }
        .disabled(recording == nil)
    }
}

// MARK: Meeting page

struct MeetingView: View {
    @EnvironmentObject var model: Model
    let recording: Recording
    @State private var entries: [Entry] = []
    @State private var title = ""
    @FocusState private var editingTitle: Bool

    var body: some View {
        let colors = speakerColors(entries)
        Group {
            if entries.isEmpty {
                VStack(spacing: 0) {
                    column { header(colors) }
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    column {
                        header(colors)
                        Divider()
                        TranscriptView(entries: entries, colors: colors, audio: recording.audio)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar(recording: recording) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Menu("Transcribe Again") { TranscribeOptions(recording: recording) }
                        .disabled(model.transcribing[recording.id] != nil)
                    Button("Copy Transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entries.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n"), forType: .string)
                    }
                    .disabled(entries.isEmpty)
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                    Divider()
                    Button("Move to Trash") { model.trash(recording) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("More")
            }
        }
        .task(id: "\(recording.id)|\(model.revision)|\(recording.hasTranscript)") {
            entries = model.entries(for: recording)
            if !editingTitle { title = recording.label } // a recording elsewhere refreshes this while you type
        }
    }

    /// The readable column every meeting page uses.
    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func header(_ colors: [String: Color]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled Meeting", text: $title)
                .textFieldStyle(.plain)
                .font(.title.bold())
                .focused($editingTitle)
                .onSubmit { model.rename(recording, to: title) }
                .onChange(of: editingTitle) { if !editingTitle { model.rename(recording, to: title) } }
            Text(dateLine).foregroundStyle(.secondary)
        }
        if !colors.isEmpty {
            HStack(spacing: 8) {
                ForEach(colors.keys.sorted { $0 == "Me" || ($1 != "Me" && $0 < $1) }, id: \.self) { speaker in
                    SpeakerChip(name: speaker, color: colors[speaker]!) { model.renameSpeaker(in: recording, from: speaker, to: $0) }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if let progress = model.transcribing[recording.id] {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(progress)
            }
        } else if recording.transcribed {
            ContentUnavailableView {
                Label("No Speech Detected", systemImage: "waveform.slash")
            } description: {
                Text("Nothing was said in this recording.")
            } actions: {
                Button("Move to Trash") { model.trash(recording) }
            }
        } else {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "text.bubble")
            } description: {
                Text("Transcribe the saved audio on this Mac.")
            } actions: {
                Button("Transcribe") { model.transcribe(recording) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var dateLine: String {
        let date = recording.date.map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()) } ?? recording.folder
        return "\(date) · \(formatDuration(recording.duration))"
    }
}

/// Playback along the bottom of a meeting, like Voice Memos.
struct PlayerBar: View {
    @EnvironmentObject var model: Model
    let recording: Recording
    @State private var scrubbing: Double?

    var body: some View {
        let file = recording.audio
        let isPlaying = model.playing == file
        TimelineView(.animation(minimumInterval: 0.25, paused: !isPlaying)) { _ in
            let time = scrubbing ?? model.position(of: file)
            HStack(spacing: 10) {
                Button {
                    model.togglePlayback(file)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play. Click any timestamp to jump there.")
                Text(formatDuration(time))
                    .frame(minWidth: 44, alignment: .trailing)
                Slider(value: Binding(get: { time }, set: { scrubbing = $0 }), in: 0...max(recording.duration, 1)) { editing in
                    if !editing, let scrubbing {
                        model.seek(file, to: scrubbing)
                        self.scrubbing = nil
                    }
                }
                .controlSize(.small)
                Text(formatDuration(recording.duration))
                    .frame(minWidth: 44, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .disabled(!FileManager.default.fileExists(atPath: file.path))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SpeakerChip: View {
    let name: String
    let color: Color
    let onRename: (String) -> Void
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        Button {
            text = name
            editing = true
        } label: {
            HStack(spacing: 6) {
                Avatar(name: name, color: color, size: 18)
                Text(name)
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename \(name)")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Who is \(name)?").font(.headline)
                TextField("Name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit {
                        onRename(text)
                        editing = false
                    }
            }
            .padding(14)
        }
    }
}

/// A Contacts-style monogram.
struct Avatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        let initial = name.hasPrefix("Speaker ") ? String(name.dropFirst(8)) : String(name.prefix(1)).uppercased()
        Circle()
            .fill(color.gradient)
            .overlay(Text(initial).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// Consecutive lines from the same speaker in the same language, shown as one paragraph.
struct Block: Identifiable {
    let speaker: String
    let start: Double
    var end: Double
    var lines: [Entry]
    var id: String { "\(start)|\(speaker)" }
}

func blocks(_ entries: [Entry]) -> [Block] {
    var result: [Block] = []
    for entry in entries {
        if let last = result.last, last.speaker == entry.speaker, last.lines.last?.language == entry.language, entry.start - last.end < 20 {
            result[result.count - 1].lines.append(entry)
            result[result.count - 1].end = max(last.end, entry.end)
        } else {
            result.append(Block(speaker: entry.speaker, start: entry.start, end: entry.end, lines: [entry]))
        }
    }
    return result
}

struct TranscriptView: View {
    @EnvironmentObject var model: Model
    let entries: [Entry]
    let colors: [String: Color]
    let audio: URL?

    var body: some View {
        let multilingual = Set(entries.compactMap(\.language)).count > 1
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(blocks(entries)) { block in
                let active = audio != nil && model.playing == audio && (block.start..<max(block.end, block.start + 1)).contains(model.playbackTime)
                BlockView(block: block, color: colors[block.speaker] ?? .gray, active: active, showLanguage: multilingual) { time in
                    if let audio { model.play(audio, from: time) }
                }
                .id(block.id)
            }
        }
    }
}

struct BlockView: View {
    let block: Block
    let color: Color
    let active: Bool
    let showLanguage: Bool
    let onPlay: ((Double) -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if hovering, let onPlay {
                // Like a track number in Music, the avatar turns into a play button on hover.
                Button { onPlay(block.start) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play from \(formatDuration(block.start))")
            } else {
                Avatar(name: block.speaker, color: color)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(block.speaker).fontWeight(.semibold)
                    Button {
                        onPlay?(block.start)
                    } label: {
                        Text(formatDuration(block.start)).monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(hovering && onPlay != nil ? Color.accentColor : .secondary)
                    .disabled(onPlay == nil)
                    .help("Play from here")
                    if showLanguage, let language = block.lines.first?.language {
                        Text(language.uppercased())
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(block.lines.map(\.text).joined(separator: " "))
                    .font(.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(active ? Color.accentColor.opacity(0.1) : hovering ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

// MARK: Live page

struct LiveView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Group {
            if model.liveEntries.isEmpty {
                VStack(spacing: 0) {
                    column { header }
                    ContentUnavailableView {
                        Label("Listening…", systemImage: "waveform")
                            .symbolEffect(.variableColor.iterative)
                    } description: {
                        Text("The transcript appears here as people speak.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        column {
                            header
                            Divider()
                            TranscriptView(entries: model.liveEntries, colors: speakerColors(model.liveEntries), audio: nil)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .onChange(of: model.liveEntries.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { RecorderBar() }
    }

    /// Same header as a saved meeting, so the page doesn't jump when the recording ends.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New Recording").font(.title.bold())
            Text((model.startedAt ?? model.now).formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
                .foregroundStyle(.secondary)
        }
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
    }
}

/// The recording counterpart of PlayerBar: time, language and Stop along the bottom.
struct RecorderBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 8, height: 8).symbolEffect(.pulse, isActive: !model.stopping)
            Text(formatDuration(model.now.timeIntervalSince(model.startedAt ?? model.now)))
                .font(.title3.monospacedDigit())
            Spacer()
            if model.stopping {
                ProgressView().controlSize(.small)
                Text(model.status).foregroundStyle(.secondary).lineLimit(1)
                Button("Skip") { model.skipPending() }
                    .help("Skip this step; the audio and transcript are saved")
            } else {
                Picker("Language", selection: $model.language) {
                    ForEach(languages, id: \.0) { code, name in Text(code == "auto" ? "Auto-detect" : name).tag(code) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Language for the rest of the meeting")
                Button("Stop") { model.stopRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop recording (Esc)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: Model

    var body: some View {
        ContentUnavailableView {
            Label("No Meeting Selected", systemImage: "waveform")
        } description: {
            Text("Record any call: your voice and what you hear. Everything stays on this Mac.")
        } actions: {
            Button("New Recording") { model.startRecording() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $model.language) { LanguageOptions() }
                Toggle("Record my microphone", isOn: $model.mic)
                Toggle("Show floating transcript while recording", isOn: $model.floatingTranscript)
            } header: {
                Text("Recording")
            } footer: {
                Text("Language is detected per sentence, so a meeting can switch languages. Turn off the microphone to record only what you hear.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Transcription", selection: $model.transcriptionModel) {
                    ForEach(transcriptionModels) { Text($0.name).tag($0.id) }
                }
                Picker("Titles", selection: $model.titleModel) {
                    ForEach(titleModels) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Speakers", value: "pyannote community-1")
            } header: {
                Text("Models")
            } footer: {
                Text("Models run on this Mac's GPU and download the first time they're used. Changing one restarts the transcription server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription Server") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.serverColor).frame(width: 8, height: 8)
                        Text(model.serverText)
                    }
                }
                HStack {
                    if model.server == .stopped {
                        Button("Start Server") { model.startServer() }
                    } else {
                        Button("Stop Server") { model.stopServer() }
                    }
                    Button("Open Logs") { NSWorkspace.shared.open(serverLog) }
                }
            }
            Section {
                if model.voices.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(model.voices.keys.sorted(), id: \.self) { name in
                    LabeledContent(name) {
                        HStack(spacing: 12) {
                            let meetings = model.voices[name]?.meetings ?? 0
                            Text(meetings == 1 ? "1 meeting" : "\(meetings) meetings").foregroundStyle(.secondary)
                            Button("Forget") { model.forgetVoice(name) }
                        }
                    }
                }
            } header: {
                Text("Voices")
            } footer: {
                Text("When you name a speaker in a meeting, Mel remembers their voice and names them in future meetings. Voiceprints stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Recordings") {
                    Text(recordingsDir.path).lineLimit(1).truncationMode(.middle)
                }
                Button("Show in Finder") { NSWorkspace.shared.open(recordingsDir) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
    }
}

// MARK: Menu bar

/// A native menu, like the rest of the menu bar.
struct MenuBarMenu: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRecording {
            Text("Recording · \(formatDuration(model.now.timeIntervalSince(model.startedAt ?? model.now)))")
            Button("Stop Recording") { model.stopRecording() }
                .keyboardShortcut("s")
                .disabled(model.stopping)
            Button("Show Floating Transcript") { FloatingTranscript.shared.show() }
        } else {
            Button("New Recording") { model.startRecording() }
                .keyboardShortcut("r")
            Picker("Language", selection: $model.language) { LanguageOptions() }
            Toggle("Record My Microphone", isOn: $model.mic)
        }
        Divider()
        Button("Open Mel") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Text(model.serverText)
        Divider()
        Button("Quit Mel") { model.quit() }
            .keyboardShortcut("q")
    }
}

// MARK: Floating transcript

struct FloatingTranscriptView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8).symbolEffect(.pulse)
                Text(formatDuration(model.now.timeIntervalSince(model.startedAt ?? model.now)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer()
                Button {
                    model.stopRecording()
                } label: {
                    // Drawn by hand: the panel never becomes key, so a system button would look inactive.
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Color.red.opacity(model.stopping ? 0.4 : 1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.stopping)
                .help("Stop recording")
                Button {
                    FloatingTranscript.shared.hide()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide (Window › Show Floating Transcript brings it back)")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider().opacity(0.5)
            if model.liveEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 22))
                        .symbolEffect(.variableColor.iterative)
                    Text(model.stopping ? model.status : "Listening…")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.liveEntries.suffix(60)) { Bubble(entry: $0) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.liveEntries.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()  // no title bar space: the header is the title bar
        .frame(minWidth: 260, minHeight: 160)
        // Dark on any wallpaper or window behind it, like Granola's.
        .background(Color(white: 0.11).opacity(0.82))
        .background(VisualEffect().ignoresSafeArea())
    }
}

/// Messages-style: your words on the right in blue, everyone else on the left.
struct Bubble: View {
    let entry: Entry

    var body: some View {
        let mine = entry.speaker == "Me"
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(mine ? Color.accentColor : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// The translucent HUD material behind the floating transcript.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
