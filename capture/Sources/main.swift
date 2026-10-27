// Captures system audio + microphone with ScreenCaptureKit (no virtual audio driver needed)
// and writes framed 16 kHz mono Int16 PCM to stdout:
//   [source: u8 (0 = mic, 1 = system)] [pts seconds: f64 LE] [frames: u32 LE] [frames x i16 LE]
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
let writeLock = NSLock()

func log(_ message: String) {
    FileHandle.standardError.write(Data("[capture] \(message)\n".utf8))
}

func emit(source: UInt8, pts: Double, buffer: AVAudioPCMBuffer) {
    let frames = Int(buffer.frameLength)
    guard frames > 0, let samples = buffer.int16ChannelData?[0] else { return }
    var packet = Data(capacity: 13 + frames * 2)
    packet.append(source)
    withUnsafeBytes(of: pts.bitPattern.littleEndian) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(frames).littleEndian) { packet.append(contentsOf: $0) }
    packet.append(UnsafeBufferPointer(start: samples, count: frames))

    writeLock.lock()
    defer { writeLock.unlock() }
    packet.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { exit(0) } // reader went away
            offset += n
        }
    }
}

/// Converts whatever format a stream delivers (usually 48 kHz float) to 16 kHz mono Int16.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        if inputFormat != format {
            converter = AVAudioConverter(from: format, to: outFormat)
            converter?.downmix = true
            inputFormat = format
        }
        guard let converter else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)

        return try? sampleBuffer.withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return nil }
            input.frameLength = frames
            let capacity = AVAudioFrameCount(Double(frames) * outFormat.sampleRate / format.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            return error == nil ? output : nil
        }
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let resamplers: [SCStreamOutputType: Resampler] = [.microphone: Resampler(), .audio: Resampler()]

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: UInt8
        switch type {
        case .microphone: source = 0
        case .audio: source = 1
        default: return // video frames are ignored
        }
        guard sampleBuffer.isValid, let buffer = resamplers[type]?.convert(sampleBuffer) else { return }
        emit(source: source, pts: sampleBuffer.presentationTimeStamp.seconds, buffer: buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        exit(1)
    }
}

signal(SIGPIPE, SIG_IGN)
let captureMic = !CommandLine.arguments.contains("--no-mic")
let capture = Capture()
var activeStream: SCStream?

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            log("no display found")
            exit(1)
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = captureMic
        config.sampleRate = 48_000
        config.channelCount = 2
        // ScreenCaptureKit always captures video; keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: capture)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "mel.screen"))
        try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: DispatchQueue(label: "mel.system"))
        if captureMic {
            try stream.addStreamOutput(capture, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "mel.mic"))
        }
        try await stream.startCapture()
        activeStream = stream
        log("capturing system audio\(captureMic ? " + microphone" : "")")
    } catch {
        log("failed to start: \(error.localizedDescription)")
        log("grant Screen & System Audio Recording and Microphone access to the app running mel (your terminal or Mel) in System Settings › Privacy & Security, then restart it")
        exit(1)
    }
}

dispatchMain()
