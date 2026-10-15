import SwiftUI

/// The inspector's task switcher, docked at the top of the panel: six
/// evenly spaced icon tabs and a short ink indicator that glides beneath
/// the current one. The parent owns the existing routing binding.
struct EditorInspectorTabBar: View {
    static let height: CGFloat = 60
    @Binding var selection: InspectorTab
    let isCropping: Bool
    let cameraAvailable: Bool
    let audioAvailable: Bool
    let cursorAvailable: Bool
    @State private var hoveredTab: InspectorTab?
    @State private var tabFrames: [InspectorTab: CGRect] = [:]
    @State private var shock: Shockwave?
    @State private var shockTask: Task<Void, Never>?
    @Namespace private var indicator

    private struct Shockwave: Equatable {
        let id: Int
        let center: CGPoint
        let color: Color
    }

    // Same grammar as the Settings navigation island: 44 pt targets, only
    // the current task shows its name, one pill glides between them.
    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .coordinateSpace(name: "inspector.nav")
        .animation(SpringMotion.hover, value: hoveredTab)
        .disabled(isCropping)
        .opacity(isCropping ? 0.45 : 1)
        .overlay(alignment: .topLeading) {
            if let shock {
                EditorNavShockwave(center: shock.center, color: shock.color)
                    .id(shock.id)
                    .allowsHitTesting(false)
            }
        }
        // The ring is drawn by this bar but has to travel over the page below.
        .zIndex(2)
        .onChange(of: selection) { _, tab in
            shockTask?.cancel()
            guard !RecorderMotion.reduces else { return }
            // The new tab widens as its name appears; read its frame once
            // that has started so the ring leaves from where the pill lands.
            shockTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard !Task.isCancelled, let frame = tabFrames[tab], selection == tab else { return }
                shock = Shockwave(
                    id: (shock?.id ?? 0) + 1,
                    center: CGPoint(x: frame.midX, y: frame.midY),
                    color: EditorConsole.palette(for: tab).fill
                )
            }
        }
        .onDisappear {
            shockTask?.cancel()
            shockTask = nil
            shock = nil
        }
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let selected = selection == tab
        let hovered = hoveredTab == tab && !selected
        return AppChoiceButton(isSelected: selected) {
            guard selection != tab else { return }
            withAnimation(SpringMotion.settle) { selection = tab }
        } label: {
            HStack(spacing: 7) {
                AppLineIcon(kind: tab.lineIcon, size: 17)
                    .modifier(AppChoiceIconFeedback())
                if selected {
                    Text(tab.localizedLabel)
                        .font(.appUI(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.settingsLabel)
                }
            }
            .modifier(AppChoiceContentFeedback())
            .foregroundStyle(
                selected
                    ? EditorConsole.palette(for: tab).ink
                    : hovered ? EditorTheme.primaryText : EditorTheme.secondaryText
            )
            .padding(.leading, selected ? 14 : 0)
            .padding(.trailing, selected ? 16 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                if selected {
                    // The current task's own colour: the pill carries it as it
                    // glides from one task to the next.
                    Capsule(style: .continuous)
                        .fill(EditorConsole.palette(for: tab).fill)
                        .matchedGeometryEffect(id: "inspector.tab.thumb", in: indicator)
                } else if hovered {
                    Circle().fill(SettingsTheme.hover)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("inspector.nav"))
            } action: { tabFrames[tab] = $0 }
        }
        .disabled(!isAvailable(tab))
        .opacity(isAvailable(tab) ? 1 : 0.35)
        .help(help(for: tab))
        .accessibilityLabel(tab.localizedLabel)
        .accessibilityIdentifier("editor.workspace.tool.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering in
            if hovering { hoveredTab = tab } else if hoveredTab == tab { hoveredTab = nil }
        }
    }

    private func isAvailable(_ tab: InspectorTab) -> Bool {
        switch tab {
        case .camera: cameraAvailable
        case .audio: audioAvailable
        case .cursor: cursorAvailable
        case .frame, .opening, .zoom, .subtitle: true
        }
    }

    private func help(for tab: InspectorTab) -> String {
        guard !isAvailable(tab) else { return tab.localizedLabel }
        switch tab {
        case .camera: return appLocalized("当前项目没有摄像头素材")
        case .audio: return appLocalized("当前项目没有系统声音或麦克风素材")
        case .cursor: return appLocalized("当前项目没有记录鼠标事件")
        case .frame, .opening, .zoom, .subtitle: return tab.localizedLabel
        }
    }
}

/// A thin ring and a faint disc leaving the pressed tab, both fading out
/// well before they cross the whole panel.
private struct EditorNavShockwave: View {
    let center: CGPoint
    let color: Color
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.10))
                .frame(width: 40, height: 40)
                .scaleEffect(expanded ? 30 : 0.2)
                .opacity(expanded ? 0 : 1)
            Circle()
                .strokeBorder(color, lineWidth: 2)
                .frame(width: 40, height: 40)
                .scaleEffect(expanded ? 22 : 0.2)
                .opacity(expanded ? 0 : 0.9)
        }
        .position(center)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.95)) { expanded = true }
        }
    }
}
