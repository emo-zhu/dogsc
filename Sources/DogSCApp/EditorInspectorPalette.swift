import AppKit
import SwiftUI

/// One colour identity per task. The same hue marks a task in the inspector
/// (its selected key, bars, knob arcs) and the things that belong to it on
/// the canvas and the timeline (selection outlines, handles, markers), so a
/// selection is never just "the default black".
///
/// Flat fills only: no gradients, glows or tinted backgrounds.
struct EditorConsolePalette: Equatable {
    /// Solid fill that always carries `ink` on top: selected thumbs, bars.
    let fill: Color
    /// Lines, arcs and outlines drawn directly on a surface. Deeper than
    /// `fill` in the light appearance so they keep their contrast.
    let stroke: Color
    /// Foreground for anything drawn on `fill`: a deep shade of the same
    /// hue, which sits on the colour far more calmly than black.
    let ink: Color
    /// A light wash of the hue for large areas (timeline clips), and the
    /// text that goes on it: the deep shade in light, the hue in dark.
    let soft: Color
    let softInk: Color
    /// The hue as small text on the panel: deep enough for 4.5:1 in the
    /// light appearance, the hue itself in dark.
    let text: Color
}

private func paletteRGB(_ hex: UInt32) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

enum EditorConsole {
    static let scrollSpace = "inspector.scroll"

    private static func vivid(fill: UInt32, lightStroke: UInt32, ink: UInt32, lightText: UInt32) -> EditorConsolePalette {
        let fillColor = paletteRGB(fill)
        // In dark, text on the hue's wash is the hue lifted toward white so
        // a selected (stronger) wash still keeps 5.7:1 or more.
        let liftedFill = fillColor.blended(withFraction: 0.35, of: .white) ?? fillColor
        return EditorConsolePalette(
            fill: Color(nsColor: fillColor),
            stroke: Color(nsColor: RecorderStyle.adaptive(paletteRGB(lightStroke), fillColor)),
            ink: Color(nsColor: paletteRGB(ink)),
            soft: Color(nsColor: RecorderStyle.adaptive(
                fillColor.withAlphaComponent(0.2), fillColor.withAlphaComponent(0.2)
            )),
            softInk: Color(nsColor: RecorderStyle.adaptive(paletteRGB(ink), liftedFill)),
            text: Color(nsColor: RecorderStyle.adaptive(paletteRGB(lightText), fillColor))
        )
    }

    // Each ink is the fill's own deep shade (contrast on the fill 5.6–8.5:1).
    static let frame = vivid(fill: 0x5AAEFF, lightStroke: 0x1E73E8, ink: 0x062B57, lightText: 0x1A66D2)
    static let opening = vivid(fill: 0xFF8550, lightStroke: 0xDD4A12, ink: 0x4A1600, lightText: 0xC2410A)
    static let zoom = vivid(fill: 0xFFB830, lightStroke: 0xC27A00, ink: 0x4A2C00, lightText: 0x9A6200)
    static let cursor = vivid(fill: 0xB5E655, lightStroke: 0x578C00, ink: 0x283A00, lightText: 0x4A7A00)
    static let camera = vivid(fill: 0xFF6B92, lightStroke: 0xDC2C5C, ink: 0x4D0A24, lightText: 0xC8264F)
    static let audio = vivid(fill: 0x3DDBB0, lightStroke: 0x008F68, ink: 0x003F2E, lightText: 0x007A5A)
    static let subtitle = vivid(fill: 0x8F7CF6, lightStroke: 0x5B3FD6, ink: 0x241356, lightText: 0x6D4FE0)

    static func palette(for tab: InspectorTab) -> EditorConsolePalette {
        switch tab {
        case .frame: frame
        case .opening: opening
        case .zoom: zoom
        case .cursor: cursor
        case .camera: camera
        case .audio: audio
        case .subtitle: subtitle
        }
    }

    /// The identity of a selected object. Mosaics and stickers belong to the
    /// opening/overlay family; anything about the screen itself is "frame".
    static func palette(for selection: EditorSelection) -> EditorConsolePalette {
        switch selection {
        case .canvas, .screen, .primarySegment, .crop: frame
        case .zoomTrack, .zoom, .screenMotionTrack, .screenMotion: zoom
        case .cursor: cursor
        case .camera, .cameraMotion: camera
        case .audio: audio
        case .mosaic, .sticker: opening
        case .subtitleCue: subtitle
        }
    }
}

private struct ConsolePaletteKey: EnvironmentKey {
    static let defaultValue: EditorConsolePalette? = nil
}

extension EnvironmentValues {
    /// Nil outside the editor inspector and the canvas/timeline objects that
    /// opt in, where controls keep their quiet platinum look.
    var consolePalette: EditorConsolePalette? {
        get { self[ConsolePaletteKey.self] }
        set { self[ConsolePaletteKey.self] = newValue }
    }
}
