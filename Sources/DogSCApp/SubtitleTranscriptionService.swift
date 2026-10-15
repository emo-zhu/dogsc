import AVFoundation
import Foundation
import RecorderCore
@preconcurrency import Speech

enum SubtitleTranscriptionError: LocalizedError {
    case speechUnavailable
    case notAuthorized
    case noTranscription

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "当前语言的语音识别不可用，请更换语言后重试。"
        case .notAuthorized:
            return "语音识别权限被拒绝，请在系统设置中允许后重试。"
        case .noTranscription:
            return "没有识别到任何语音。请确认视频中有清晰人声，且语言选择与说话语言一致。"
        }
    }
}

/// One transcription request. The prepared composition is opaque across the
/// task boundary — exactly like `DirectExportPipeline`, the export session and
/// readers are the only consumers, and one request owns them exclusively.
struct SubtitleTranscriptionInput: @unchecked Sendable {
    let media: TimelineCompositionBundle
    let project: RecorderProject
    let localeIdentifier: String
}

/// Generates output-clock subtitle cues from the editor's mixed audio.
///
/// The same cut/retimed/volume audio heard during playback is rendered to a
/// temporary M4A through ``AudioOnlyExportPipeline``, then transcribed with
/// the system Speech framework. Recognized timestamps land on the output
/// clock directly, so cues attach to the timeline without remapping.
final class SubtitleTranscriptionService: @unchecked Sendable {
    /// A phrase breaks when the speaker pauses, or the block would grow past
    /// readable caption limits.
    private static let maximumPhraseGap: TimeInterval = 0.55
    private static let maximumPhraseCharacters = 42
    private static let maximumPhraseSpan: TimeInterval = 5

    private static let exportProgressWeight = 0.35

    /// "Follow the interface": resolve the recognizer locale from the app's
    /// preferred localization instead of forcing a fixed language.
    static let automaticLanguageID = "auto"

    static func resolvedLocaleIdentifier(selected: String) -> String {
        guard selected == automaticLanguageID else { return selected }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if Locale(identifier: preferred).language.languageCode == .chinese {
            // The recognizer wants a script-qualified Mandarin identifier.
            return preferred.hasPrefix("zh-Hant") ? "zh-TW" : "zh-CN"
        }
        return Locale(identifier: preferred).identifier
    }

    private let temporaryDirectory: URL

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    func generateCues(
        input: SubtitleTranscriptionInput,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        try await Self.requestAuthorization()
        let media = input.media

        let audioURL = temporaryDirectory.appending(
            path: "subtitle-audio-\(UUID().uuidString).m4a"
        )
        let pipeline = try AudioOnlyExportPipeline(
            media: media,
            outputURL: audioURL,
            project: input.project
        ) { fraction in
            progress?(min(max(fraction, 0), 1) * Self.exportProgressWeight)
        }
        try await pipeline.run()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try Task.checkCancellation()

        return try await transcribe(
            audioURL: audioURL,
            localeIdentifier: input.localeIdentifier,
            outputDuration: media.plan.outputDuration
        ) { fraction in
            progress?(
                Self.exportProgressWeight
                    + min(max(fraction, 0), 1) * (1 - Self.exportProgressWeight)
            )
        }
    }

    // MARK: - Authorization

    private static func requestAuthorization() async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            try Self.validateAuthorization(SFSpeechRecognizer.authorizationStatus())
            return
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        try Self.validateAuthorization(status)
    }

    private static func validateAuthorization(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) throws {
        guard status == .authorized else {
            throw SubtitleTranscriptionError.notAuthorized
        }
    }

    // MARK: - Recognition

    /// The recognizer surfaces empty-audio failures as raw NSErrors whose
    /// localized description is English-only ("No speech detected"). Map the
    /// known no-speech codes (203 = recognition failure, 1110 = no speech
    /// recognized) onto the local error so the UI shows an actionable message
    /// instead of leaking the framework string.
    private static func normalizedSpeechError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == "kAFAssistantErrorDomain",
              nsError.code == 203 || nsError.code == 1110 else {
            return error
        }
        return SubtitleTranscriptionError.noTranscription
    }

    private func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        outputDuration: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SubtitleCue] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw SubtitleTranscriptionError.speechUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Prefer the private on-device model; a locale without one falls back
        // to the standard recognizer instead of failing the whole generation.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let taskBox = RecognitionTaskBox()
        let finalResult: SFSpeechRecognitionResult = try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let once = ResumeOnce()
                    taskBox.task = recognizer.recognitionTask(with: request) {
                        result,
                        error in
                        if let result {
                            if result.isFinal {
                                once.run { continuation.resume(returning: result) }
                            } else {
                                Self.reportProgress(
                                    segments: result.bestTranscription.segments,
                                    outputDuration: outputDuration,
                                    progress: progress
                                )
                            }
                        } else if let error {
                            once.run { continuation.resume(throwing: Self.normalizedSpeechError(error)) }
                        }
                    }
                }
            },
            onCancel: {
                taskBox.task?.finish()
            }
        )

        let cues = Self.mergeSegments(
            finalResult.bestTranscription.segments,
            outputDuration: outputDuration
        )
        guard !cues.isEmpty else {
            throw SubtitleTranscriptionError.noTranscription
        }
        progress(1)
        return cues
    }

    private static func reportProgress(
        segments: [SFTranscriptionSegment],
        outputDuration: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        guard let last = segments.last, outputDuration.isFinite, outputDuration > 0 else {
            return
        }
        let recognizedEnd = last.timestamp + last.duration
        progress(
            min(max(recognizedEnd / outputDuration, 0), 0.99)
        )
    }

    // MARK: - Phrase merging

    /// Word-level recognizer segments are far too granular for captions.
    /// Group them into readable phrases using pause, length and span limits.
    /// Each segment keeps its own window as a ``SubtitleWord`` so the renderer
    /// can highlight the word being spoken inside the finished phrase.
    static func mergeSegments(
        _ segments: [SFTranscriptionSegment],
        outputDuration: TimeInterval
    ) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var text = ""
        var start: TimeInterval?
        var end: TimeInterval = 0
        var words: [SubtitleWord] = []

        func flush() {
            guard let currentStart = start, !text.isEmpty else { return }
            let duration = max(end - currentStart, 0.4)
            cues.append(
                SubtitleCue(
                    timing: OverlayTiming(startTime: currentStart, duration: duration),
                    text: text,
                    words: words
                )
            )
            text = ""
            start = nil
            words = []
        }

        for segment in segments {
            let piece = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let pieceStart = max(segment.timestamp, 0)
            let pieceEnd = min(
                pieceStart + max(segment.duration, 0.2),
                outputDuration.isFinite && outputDuration > 0
                    ? outputDuration
                    : .greatestFiniteMagnitude
            )
            if let currentStart = start,
               pieceStart - end > maximumPhraseGap
                   || text.count + piece.count > maximumPhraseCharacters
                   || pieceEnd - currentStart > maximumPhraseSpan {
                flush()
            }
            if start == nil {
                start = pieceStart
                text = piece
            } else {
                // CJK segments arrive without spaces; others keep theirs.
                let needsSpace: Bool
                if let lastCharacter = text.last, let firstCharacter = piece.first,
                   lastCharacter.isLetter, firstCharacter.isLetter {
                    needsSpace = !lastCharacter.isCJK && !firstCharacter.isCJK
                } else {
                    needsSpace = false
                }
                text += needsSpace ? " \(piece)" : piece
            }
            end = max(end, pieceEnd)
            if let cueStart = start {
                // Word offsets are stored relative to the phrase so every later
                // timeline edit moves the cue and its words together.
                words.append(
                    SubtitleWord(text: piece, offset: pieceStart - cueStart)
                )
            }
        }
        flush()
        return cues
    }
}

private final class RecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SFSpeechRecognitionTask?

    var task: SFSpeechRecognitionTask? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Guarantees a continuation resumes exactly once when the Speech task may
/// still deliver an error after its final result.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ body: () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        body()
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
