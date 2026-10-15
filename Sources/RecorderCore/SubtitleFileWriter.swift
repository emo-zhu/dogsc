import Foundation

/// Plain-text caption exchange formats the subtitle track can be written to.
/// Both are read by players, editors and review tools.
public enum SubtitleFileFormat: String, CaseIterable, Sendable {
    case srt
    case vtt

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .srt: return "SRT"
        case .vtt: return "WebVTT"
        }
    }
}

/// Serializes ``SubtitleCue`` values to SRT / WebVTT.
///
/// Cues are authored on the output clock, so a written file is a direct
/// projection of the edited timeline and stays aligned through cuts, retiming
/// and reordering. When an export ``MediaTimeRange`` is supplied the file is
/// rebased to start at zero, exactly like the encoded video, and cues are
/// clipped to the exported window.
public enum SubtitleFileWriter {
    public static func serialize(
        cues: [SubtitleCue],
        format: SubtitleFileFormat,
        outputRange: MediaTimeRange? = nil
    ) -> String {
        let resolved = resolve(cues: cues, outputRange: outputRange)
        switch format {
        case .srt: return srt(resolved)
        case .vtt: return vtt(resolved)
        }
    }

    /// A cue intersected with the export window and rebased to file time.
    /// Public so the movie exporter can embed the very same resolved cues as an
    /// in-file text track instead of re-deriving the clipping rules.
    public struct ResolvedCue: Equatable, Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    // MARK: - Reading

    /// Parses SRT or WebVTT text into output-clock cues. Both formats share the
    /// same `start --> end` block shape, so one reader covers them; a `WEBVTT`
    /// header, an SRT index line or a VTT cue identifier are all skipped.
    /// Imported cues are absolute file times, which the editor already treats
    /// as output-clock time.
    public static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") {
            lines.removeFirst()
        }
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            var block: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(lines[index])
                index += 1
            }
            index += 1 // Consume the blank line separating blocks.
            guard let arrowIndex = block.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let sides = block[arrowIndex].components(separatedBy: "-->")
            guard sides.count == 2 else { continue }
            let endToken = sides[1]
                .split(separator: " ")
                .first
                .map(String.init) ?? sides[1]
            guard let start = parseTimecode(sides[0]),
                  let end = parseTimecode(endToken),
                  end > start else { continue }
            let text = block[(arrowIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(
                SubtitleCue(
                    timing: OverlayTiming(startTime: start, duration: end - start),
                    text: text
                )
            )
        }
        return cues.sorted { $0.timing.startTime < $1.timing.startTime }
    }

    /// Accepts both `HH:MM:SS,mmm` and `MM:SS.mmm` (and the VTT dot form).
    static func parseTimecode(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts[parts.count - 1]) else { return nil }
        var total = seconds
        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]) else {
                return nil
            }
            total += hours * 3600 + minutes * 60
        default:
            guard let minutes = Double(parts[0]) else { return nil }
            total += minutes * 60
        }
        return total.isFinite ? total : nil
    }


    public static func resolve(
        cues: [SubtitleCue],
        outputRange: MediaTimeRange?
    ) -> [ResolvedCue] {
        let windowStart = outputRange?.start ?? 0
        let windowEnd = outputRange?.end ?? .infinity
        return cues
            .filter(\.isRenderable)
            .compactMap { cue -> ResolvedCue? in
                let start = max(cue.timing.startTime, windowStart)
                let end = min(cue.timing.endTime, windowEnd)
                guard end > start else { return nil }
                let relativeStart = start - windowStart
                let relativeEnd = end - windowStart
                // Zero-length cues cannot be represented: the rounded
                // timestamps would be identical and players reject them.
                guard milliseconds(relativeEnd) > milliseconds(relativeStart) else {
                    return nil
                }
                return ResolvedCue(
                    start: relativeStart,
                    end: relativeEnd,
                    text: normalizedText(cue.text)
                )
            }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func timecode(_ time: TimeInterval, format: SubtitleFileFormat) -> String {
        let total = milliseconds(time)
        let hours = total / 3_600_000
        let minutes = (total % 3_600_000) / 60_000
        let seconds = (total % 60_000) / 1000
        let millis = total % 1000
        let separator = format == .srt ? "," : "."
        return String(
            format: "%02d:%02d:%02d%@%03d",
            hours, minutes, seconds, separator, millis
        )
    }

    private static func milliseconds(_ time: TimeInterval) -> Int {
        let safe = time.isFinite ? max(time, 0) : 0
        return Int((safe * 1000).rounded())
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func srt(_ cues: [ResolvedCue]) -> String {
        var output = ""
        for (index, cue) in cues.enumerated() {
            output += "\(index + 1)\n"
            output += "\(timecode(cue.start, format: .srt)) --> "
            output += "\(timecode(cue.end, format: .srt))\n"
            output += "\(cue.text)\n\n"
        }
        return output
    }

    private static func vtt(_ cues: [ResolvedCue]) -> String {
        var output = "WEBVTT\n\n"
        for cue in cues {
            output += "\(timecode(cue.start, format: .vtt)) --> "
            output += "\(timecode(cue.end, format: .vtt))\n"
            output += "\(cue.text)\n\n"
        }
        return output
    }
}
