import Foundation

/// Fork-local addition on top of upstream schema 27. The cues and style are
/// optional decode fields with defaults, so projects written here still open
/// in upstream builds (unknown key ignored, version unchanged) and upstream
/// projects open here without migration. If upstream later claims version 28,
/// its projects are rejected by the existing future-version guard, exactly
/// like any other newer schema.
///
/// One recognized word inside a caption, timed *relative to the cue start*.
///
/// Relative offsets are deliberate: every timeline transform (ripple, insert,
/// trim, reorder, split) already rewrites ``SubtitleCue/timing`` through the
/// shared overlay math, so word times follow the cue for free instead of
/// needing their own copy of that edit logic. Only a playback-rate change has
/// to scale them, because the cue itself is stretched there.
public struct SubtitleWord: Codable, Equatable, Sendable {
    public var text: String
    /// Seconds from the cue start at which this word began.
    public var offset: TimeInterval

    public init(text: String, offset: TimeInterval) {
        self.text = text
        self.offset = offset
    }
}

/// One spoken phrase anchored to the output timeline. Subtitles are authored
/// in output time like mosaic and sticker clips, so the same ripple / insert
/// transforms keep them aligned with the video through every edit.
public struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timing: OverlayTiming
    public var text: String
    /// Word-level timing for the karaoke highlight. Empty for imported files
    /// and for cues whose text the user rewrote, in which case the cue simply
    /// renders without a highlight.
    public var words: [SubtitleWord]

    public init(
        id: UUID = UUID(),
        timing: OverlayTiming,
        text: String,
        words: [SubtitleWord] = []
    ) {
        self.id = id
        self.timing = timing
        self.text = text
        self.words = words
    }

    public var isRenderable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The UTF-16 range of the word being spoken at `time`, or nil when the cue
    /// carries no usable word timing.
    ///
    /// Every word from its start onward is a candidate and the last one wins,
    /// so the highlight holds through the short gaps between words instead of
    /// flickering off mid-phrase. Each word is located in `trimmedText` by
    /// scanning forward from the end of the previous match, so an edited
    /// caption that still contains the original words in order keeps its
    /// highlight, while a rewritten one quietly falls back to no highlight
    /// instead of coloring the wrong span.
    public func highlightRange(
        in trimmedText: String,
        at time: TimeInterval
    ) -> Range<Int>? {
        guard !words.isEmpty else { return nil }
        let localTime = time - timing.startTime
        var searchStart = trimmedText.startIndex
        var active: Range<String.Index>?
        for word in words {
            guard !word.text.isEmpty else { continue }
            guard let found = trimmedText.range(
                of: word.text,
                range: searchStart..<trimmedText.endIndex
            ) else {
                return nil
            }
            searchStart = found.upperBound
            if localTime >= word.offset - 0.001 {
                active = found
            }
        }
        guard let active else { return nil }
        return active.lowerBound.utf16Offset(in: trimmedText)
            ..< active.upperBound.utf16Offset(in: trimmedText)
    }

    /// Every key is optional on decode so a caption written before word timing
    /// existed still opens with an empty list. An empty list encodes nothing,
    /// keeping projects that never used word timing byte-identical.
    private enum CodingKeys: String, CodingKey {
        case id
        case timing
        case text
        case words
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timing = try container.decode(OverlayTiming.self, forKey: .timing)
        text = try container.decode(String.self, forKey: .text)
        words = try container.decodeIfPresent([SubtitleWord].self, forKey: .words) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timing, forKey: .timing)
        try container.encode(text, forKey: .text)
        if !words.isEmpty {
            try container.encode(words, forKey: .words)
        }
    }
}

public extension SubtitleCue {
    /// True for the CJK ranges that should join without a space when two
    /// captions are merged; shared with the line-count estimator.
    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x2E80...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE30...0xFE4F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
            || (0x3000...0x303F).contains(value)
    }

    /// Joins this caption with the one after it: union interval, texts glued
    /// with a space except between CJK characters, and word timing re-based
    /// onto the merged start. Karaoke survives only when both sides carry
    /// words — mixing timed and untimed captions cannot stay consistent.
    func merged(with next: SubtitleCue) -> SubtitleCue {
        let start = min(timing.startTime, next.timing.startTime)
        let end = max(timing.endTime, next.timing.endTime)
        var mergedWords: [SubtitleWord] = []
        if !words.isEmpty, !next.words.isEmpty {
            let shift = next.timing.startTime - start
            mergedWords = words + next.words.map {
                SubtitleWord(text: $0.text, offset: $0.offset + shift)
            }
        }
        return SubtitleCue(
            timing: OverlayTiming(startTime: start, duration: end - start),
            text: Self.joinedText(text, next.text),
            words: mergedWords
        )
    }

    /// Splits the caption in half: at the word boundary closest to the
    /// temporal midpoint when word timing is usable, otherwise at the character
    /// midpoint. The interval is divided proportionally to how much text each
    /// side keeps, and the second half's word offsets are re-based to its own
    /// start. Returns nil when the caption cannot yield two renderable cues.
    func splitAtMidpoint() -> (leading: SubtitleCue, trailing: SubtitleCue)? {
        guard text.count >= 2 else { return nil }
        let localMidpoint = timing.duration / 2

        // Locate every word in the full text the same way the renderer's
        // highlight scan does, so the split point and the karaoke spans agree.
        var wordRanges: [(word: SubtitleWord, range: Range<String.Index>)] = []
        if !words.isEmpty {
            var searchStart = text.startIndex
            var fullyLocated = true
            for word in words {
                guard !word.text.isEmpty,
                      let found = text.range(
                          of: word.text,
                          range: searchStart..<text.endIndex
                      ) else {
                    fullyLocated = false
                    break
                }
                wordRanges.append((word, found))
                searchStart = found.upperBound
            }
            if !fullyLocated { wordRanges = [] }
        }

        var splitIndex = text.index(text.startIndex, offsetBy: text.count / 2)
        var splitLocalTime = localMidpoint
        if let boundary = nearestWordBoundary(wordRanges: wordRanges, around: localMidpoint) {
            splitIndex = boundary.index
            splitLocalTime = boundary.offset
        }

        let leadingText = String(text[..<splitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingText = String(text[splitIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leadingText.isEmpty, !trailingText.isEmpty else { return nil }

        var leadingDuration = timing.duration
            * Double(text[..<splitIndex].count)
            / Double(text.count)
        if timing.duration >= 0.1 {
            leadingDuration = min(max(leadingDuration, 0.05), timing.duration - 0.05)
        } else {
            leadingDuration = timing.duration / 2
        }

        var leadingWords: [SubtitleWord] = []
        var trailingWords: [SubtitleWord] = []
        if !wordRanges.isEmpty {
            for entry in wordRanges {
                if entry.range.upperBound <= splitIndex {
                    leadingWords.append(entry.word)
                } else if entry.range.lowerBound >= splitIndex {
                    trailingWords.append(
                        SubtitleWord(
                            text: entry.word.text,
                            offset: entry.word.offset - splitLocalTime
                        )
                    )
                }
                // A word straddling the split is dropped from both halves; its
                // span would be wrong in either one.
            }
            if leadingWords.isEmpty || trailingWords.isEmpty {
                leadingWords = []
                trailingWords = []
            }
        }

        let leading = SubtitleCue(
            timing: OverlayTiming(startTime: timing.startTime, duration: leadingDuration),
            text: leadingText,
            words: leadingWords
        )
        let trailing = SubtitleCue(
            timing: OverlayTiming(
                startTime: timing.startTime + leadingDuration,
                duration: timing.duration - leadingDuration
            ),
            text: trailingText,
            words: trailingWords
        )
        return (leading, trailing)
    }

    private func nearestWordBoundary(
        wordRanges: [(word: SubtitleWord, range: Range<String.Index>)],
        around localTime: TimeInterval
    ) -> (index: String.Index, offset: TimeInterval)? {
        // Interior boundaries only: splitting before the first word or after
        // the last would empty one side.
        var best: (index: String.Index, offset: TimeInterval)?
        for entry in wordRanges.dropFirst() {
            if best == nil
                || abs(entry.word.offset - localTime) < abs(best!.offset - localTime) {
                best = (entry.range.lowerBound, entry.word.offset)
            }
        }
        return best
    }

    private static func joinedText(_ first: String, _ second: String) -> String {
        guard let last = first.last, let nextFirst = second.first else {
            return first + second
        }
        let bothCJK = last.unicodeScalars.contains(where: isCJKScalar)
            && nextFirst.unicodeScalars.contains(where: isCJKScalar)
        return bothCJK ? first + second : first + " " + second
    }
}

/// Font family presets for the caption track. Each case maps to a concrete
/// macOS face inside the renderer, so preview and export never disagree.
public enum SubtitleFontFamily: String, Codable, CaseIterable, Sendable {
    case system
    case rounded
    case serif
    case monospaced
}

/// Vertical placement of the caption block on the canvas.
public enum SubtitleAnchor: String, Codable, CaseIterable, Sendable {
    case top
    case middle
    case bottom
}

/// Horizontal alignment of the wrapped caption lines inside the text block.
public enum SubtitleTextAlignment: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

/// Global presentation style for the subtitle track. Values are validated by
/// ``ProjectValidator`` and never repaired silently.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Multiplier on the canonical 1080-short-edge caption size (34 pt).
    public var fontScale: Double
    public var fontFamily: SubtitleFontFamily
    public var textColor: HexColor
    /// Translucent caption backdrop strength behind the text block.
    public var backdropOpacity: Double
    /// Vertical anchor of the text block on the canvas.
    public var anchor: SubtitleAnchor
    /// Distance of the text block from its anchored edge, normalized against
    /// the canvas height. Ignored by the centered anchor.
    public var baselineInset: Double
    /// Horizontal alignment of the wrapped lines inside the text block.
    public var textAlignment: SubtitleTextAlignment
    /// Widest allowed text block, normalized against the canvas width.
    public var maxWidthFraction: Double
    /// Outline width as a fraction of the font size (0 = no outline).
    public var strokeWidth: Double
    public var strokeColor: HexColor
    /// Shadow strength behind the glyphs (0 = no shadow).
    public var shadowOpacity: Double
    /// Karaoke highlight: recolor the word being spoken at the sampled time.
    public var highlightEnabled: Bool
    public var highlightColor: HexColor

    public init(
        isEnabled: Bool = true,
        fontScale: Double = 1,
        fontFamily: SubtitleFontFamily = .system,
        textColor: HexColor = .white,
        backdropOpacity: Double = 0.55,
        anchor: SubtitleAnchor = .bottom,
        baselineInset: Double = 0.055,
        textAlignment: SubtitleTextAlignment = .center,
        maxWidthFraction: Double = 0.72,
        strokeWidth: Double = 0,
        strokeColor: HexColor = .black,
        shadowOpacity: Double = 0,
        highlightEnabled: Bool = false,
        highlightColor: HexColor = SubtitleStyle.defaultHighlightColor
    ) {
        self.isEnabled = isEnabled
        self.fontScale = fontScale
        self.fontFamily = fontFamily
        self.textColor = textColor
        self.backdropOpacity = backdropOpacity
        self.anchor = anchor
        self.baselineInset = baselineInset
        self.textAlignment = textAlignment
        self.maxWidthFraction = maxWidthFraction
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.shadowOpacity = shadowOpacity
        self.highlightEnabled = highlightEnabled
        self.highlightColor = highlightColor
    }

    /// Every key is optional on decode. The caption style lives inside schema
    /// 27, so a project written before a given key existed must still open and
    /// fall back to the same defaults the initializer uses.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        fontScale = try container.decodeIfPresent(Double.self, forKey: .fontScale) ?? 1
        fontFamily = try container.decodeIfPresent(
            SubtitleFontFamily.self, forKey: .fontFamily
        ) ?? .system
        textColor = try container.decodeIfPresent(HexColor.self, forKey: .textColor) ?? .white
        backdropOpacity = try container.decodeIfPresent(
            Double.self, forKey: .backdropOpacity
        ) ?? 0.55
        anchor = try container.decodeIfPresent(SubtitleAnchor.self, forKey: .anchor) ?? .bottom
        baselineInset = try container.decodeIfPresent(Double.self, forKey: .baselineInset) ?? 0.055
        textAlignment = try container.decodeIfPresent(
            SubtitleTextAlignment.self, forKey: .textAlignment
        ) ?? .center
        maxWidthFraction = try container.decodeIfPresent(
            Double.self, forKey: .maxWidthFraction
        ) ?? 0.72
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        strokeColor = try container.decodeIfPresent(HexColor.self, forKey: .strokeColor) ?? .black
        shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? 0
        highlightEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .highlightEnabled
        ) ?? false
        highlightColor = try container.decodeIfPresent(
            HexColor.self, forKey: .highlightColor
        ) ?? SubtitleStyle.defaultHighlightColor
    }

    public static let canonicalFontSize: Double = 34
    public static let backdropColor = HexColor.black
    /// Amber reads as "spoken" against the black backdrop without colliding
    /// with the white default text color.
    public static let defaultHighlightColor = HexColor(rgb24: 0xFF_C4_00)
}

public extension SubtitleStyle {
    /// Rough wrapped-line estimate used to size the caption backdrop for
    /// multi-line captions. CJK glyphs occupy one em, everything else about
    /// half an em. The raster itself is laid out by CTFramesetter in the
    /// renderer, so this only sizes the backdrop and anchors — preview and
    /// export share the same estimate and can never disagree with each other.
    static func estimatedLineCount(
        of text: String,
        usableWidth: Double,
        fontSize: Double
    ) -> Int {
        guard fontSize > 0, usableWidth > 0 else { return 1 }
        let lines = text
            .components(separatedBy: "\n")
            .map { segment -> Int in
                let width = segment.reduce(Double(0)) {
                    $0 + glyphAdvance($1, fontSize: fontSize)
                }
                return max(1, Int((width / usableWidth).rounded(.up)))
            }
        return max(1, lines.reduce(0, +))
    }

    private static func glyphAdvance(
        _ character: Character,
        fontSize: Double
    ) -> Double {
        if character.unicodeScalars.contains(where: SubtitleCue.isCJKScalar) {
            return fontSize
        }
        return fontSize * 0.55
    }

    /// Overlays `source`'s visual fields onto this style while keeping this
    /// style's enabled flag, so applying a preset (or the saved default) never
    /// flips the caption toggle underneath the user.
    func replacingVisuals(with source: SubtitleStyle) -> SubtitleStyle {
        var replaced = source
        replaced.isEnabled = isEnabled
        return replaced
    }
}

/// A named caption look for the inspector's one-click preset menu. Presets
/// carry only visual fields; the project's enabled flag survives the apply.
public struct SubtitleStylePreset: Identifiable, Equatable, Sendable {
    public let id: String
    /// Simplified-Chinese source literal, resolved through appLocalized.
    public let name: String
    public let style: SubtitleStyle

    public init(id: String, name: String, style: SubtitleStyle) {
        self.id = id
        self.name = name
        self.style = style
    }

    public static let all: [SubtitleStylePreset] = [
        SubtitleStylePreset(id: "classic", name: "经典", style: SubtitleStyle()),
        SubtitleStylePreset(id: "minimal", name: "无底衬", style: {
            var style = SubtitleStyle()
            style.backdropOpacity = 0
            style.shadowOpacity = 0.55
            return style
        }()),
        SubtitleStylePreset(id: "outline", name: "描边", style: {
            var style = SubtitleStyle()
            style.backdropOpacity = 0
            style.strokeWidth = 0.08
            style.shadowOpacity = 0.35
            return style
        }()),
        SubtitleStylePreset(id: "amber", name: "荧光黄", style: {
            var style = SubtitleStyle()
            style.textColor = SubtitleStyle.defaultHighlightColor
            style.backdropOpacity = 0.75
            style.shadowOpacity = 0.25
            return style
        }()),
    ]
}
