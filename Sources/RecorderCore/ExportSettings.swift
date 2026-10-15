import Foundation

/// How authored captions reach the exported movie.
///
/// Burning the caption into the picture is the universally readable default.
/// Embedding it as a `mov_text` (`tx3g`) text track keeps the picture clean and
/// lets the viewer toggle captions on and off, at the cost of depending on the
/// player actually honouring an embedded subtitle track.
public enum ExportSubtitleMode: String, Codable, CaseIterable, Sendable {
    case burnIn
    case softTrack
}

/// Persisted output choices for one project.
///
/// Capture configuration and canvas styling intentionally do not own these
/// values: changing an export preset must not rewrite how footage was captured
/// or introduce a second output-resolution authority in the visual model.
public struct ExportSettings: Codable, Equatable, Sendable {
    public var frameRate: OutputFrameRate
    public var resolution: CanvasResolution
    /// Fork-local addition inside schema 27. Optional on decode and omitted on
    /// encode while it keeps its default, so projects that never touched it
    /// stay byte-identical and older builds ignore the key they do not know.
    public var subtitleMode: ExportSubtitleMode

    public init(
        frameRate: OutputFrameRate = .fps60,
        resolution: CanvasResolution = .source,
        subtitleMode: ExportSubtitleMode = .burnIn
    ) {
        self.frameRate = frameRate
        self.resolution = resolution
        self.subtitleMode = subtitleMode
    }

    private enum CodingKeys: String, CodingKey {
        case frameRate
        case resolution
        case subtitleMode
    }

    /// Only ``subtitleMode`` is optional. A project written before the soft
    /// track existed must still open and fall back to burn-in, while the two
    /// original keys stay required so a malformed file is still rejected.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = try container.decode(OutputFrameRate.self, forKey: .frameRate)
        resolution = try container.decode(CanvasResolution.self, forKey: .resolution)
        subtitleMode = try container.decodeIfPresent(
            ExportSubtitleMode.self, forKey: .subtitleMode
        ) ?? .burnIn
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(resolution, forKey: .resolution)
        if subtitleMode != .burnIn {
            try container.encode(subtitleMode, forKey: .subtitleMode)
        }
    }
}
