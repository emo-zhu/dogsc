import AVFoundation
import CoreMedia
import Foundation
import RecorderCore

/// Assembles a `mov_text` (`tx3g`) subtitle track for an exported movie.
///
/// AVFoundation exposes no high-level API for authoring a text track, so the
/// format description and every sample are built here. CoreMedia's generic
/// ``CMFormatDescriptionCreate`` accepts the `sbtl`/`tx3g` pair together with
/// the text extension keys, and one caption sample is simply a big-endian
/// UTF-16 length prefix followed by the caption's UTF-8 bytes — the same shape
/// ffmpeg writes as `mov_text`. Presentation (font, colour, position) stays the
/// player's choice, since a soft track is meant to be styled by the viewer.
enum SoftSubtitleTrackWriter {
    /// Timescale for caption timestamps. Millisecond precision matches the
    /// rounding ``SubtitleFileWriter`` already applies and keeps the MP4
    /// sample table well inside 32-bit tick counts for any realistic duration.
    static let timescale: CMTimeScale = 1_000

    /// Portion of the caption sample that is not localised to the exporter.
    private enum Constants {
        /// Bottom-anchored, horizontally centred, transparent backdrop, opaque
        /// white text. Anchoring lives in the format description because there
        /// is no per-sample placement in a soft track.
        static let horizontalJustification: Int8 = 1
        static let verticalJustification: Int8 = -1
        static let fontSize: UInt8 = 18
        static let fontID: UInt16 = 1
        static let backgroundColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 0)
        static let textColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 255)
    }

    /// Caption samples ready to be handed to the writer, with the gaps between
    /// captions filled in.
    ///
    /// A gap cannot be expressed as a duration here: for a passthrough text
    /// track AVAssetWriter derives each sample's duration from the delta to the
    /// next sample's timestamp, so a caption given a shorter duration would
    /// simply linger on screen until the following cue began. An empty sample
    /// spanning the gap clears it instead, which is how the mov_text tracks
    /// this tool reads represent the same thing. Gaps shorter than
    /// ``minimumClearGap`` are left alone — the lingering caption is under a
    /// frame and an extra sample would only add noise to the sample table.
    static func playbackSamples(
        for cues: [SubtitleFileWriter.ResolvedCue]
    ) -> [SubtitleFileWriter.ResolvedCue] {
        var samples: [SubtitleFileWriter.ResolvedCue] = []
        for (index, cue) in cues.enumerated() {
            samples.append(cue)
            let nextStart = index + 1 < cues.count ? cues[index + 1].start : nil
            if let nextStart, nextStart - cue.end > minimumClearGap {
                samples.append(
                    SubtitleFileWriter.ResolvedCue(start: cue.end, end: nextStart, text: "")
                )
            }
        }
        return samples
    }

    private static let minimumClearGap: TimeInterval = 0.05

    /// One description is reused for every caption; it never varies per cue.
    static func makeFormatDescription() -> CMFormatDescription? {
        let background: [String: Any] = [
            kCMTextFormatDescriptionColor_Red as String: Int(Constants.backgroundColor.r),
            kCMTextFormatDescriptionColor_Green as String: Int(Constants.backgroundColor.g),
            kCMTextFormatDescriptionColor_Blue as String: Int(Constants.backgroundColor.b),
            kCMTextFormatDescriptionColor_Alpha as String: Int(Constants.backgroundColor.a),
        ]
        let foreground: [String: Any] = [
            kCMTextFormatDescriptionColor_Red as String: Int(Constants.textColor.r),
            kCMTextFormatDescriptionColor_Green as String: Int(Constants.textColor.g),
            kCMTextFormatDescriptionColor_Blue as String: Int(Constants.textColor.b),
            kCMTextFormatDescriptionColor_Alpha as String: Int(Constants.textColor.a),
        ]
        // A zero rectangle means "use the whole video frame" for the caption
        // box, which is what every player expects for a full-width caption.
        let textBox: [String: Any] = [
            kCMTextFormatDescriptionRect_Top as String: 0,
            kCMTextFormatDescriptionRect_Left as String: 0,
            kCMTextFormatDescriptionRect_Bottom as String: 0,
            kCMTextFormatDescriptionRect_Right as String: 0,
        ]
        let style: [String: Any] = [
            kCMTextFormatDescriptionStyle_StartChar as String: 0,
            kCMTextFormatDescriptionStyle_EndChar as String: 0,
            kCMTextFormatDescriptionStyle_Font as String: Int(Constants.fontID),
            kCMTextFormatDescriptionStyle_FontFace as String: 0,
            kCMTextFormatDescriptionStyle_FontSize as String: Int(Constants.fontSize),
            kCMTextFormatDescriptionStyle_ForegroundColor as String: foreground,
        ]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification as String:
                Int(Constants.horizontalJustification),
            kCMTextFormatDescriptionExtension_VerticalJustification as String:
                Int(Constants.verticalJustification),
            kCMTextFormatDescriptionExtension_BackgroundColor as String: background,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: textBox,
            kCMTextFormatDescriptionExtension_DefaultStyle as String: style,
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// A ready-to-append caption sample for one resolved cue, timed in output
    /// seconds (already rebased by ``SubtitleFileWriter``).
    static func makeSample(
        cue: SubtitleFileWriter.ResolvedCue,
        formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        let textBytes = Array(cue.text.utf8)
        guard textBytes.count <= Int(UInt16.max) else { return nil }
        let sampleLength = 2 + textBytes.count
        var payload: [UInt8] = [
            UInt8((textBytes.count >> 8) & 0xFF),
            UInt8(textBytes.count & 0xFF),
        ]
        payload.append(contentsOf: textBytes)
        return payload.withUnsafeBufferPointer { buffer -> CMSampleBuffer? in
            guard let base = buffer.baseAddress else { return nil }
            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: sampleLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: sampleLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
            guard CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleLength
            ) == kCMBlockBufferNoErr else { return nil }

            let start = CMTime(seconds: cue.start, preferredTimescale: timescale)
            let end = CMTime(seconds: cue.end, preferredTimescale: timescale)
            var timing = CMSampleTimingInfo(
                duration: end - start,
                presentationTimeStamp: start,
                decodeTimeStamp: .invalid
            )
            var sampleSize = sampleLength
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample
            ) == noErr else { return nil }
            return sample
        }
    }
}
