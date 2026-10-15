import SwiftUI
import RecorderCore
import UniformTypeIdentifiers

/// The subtitle task panel: transcribe the mixed editor audio into output-
/// clock captions, tune the global caption style and review every cue.
struct EditorSubtitleInspector: View {
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    let onError: (String) -> Void

    @State private var generationTask: Task<Void, Never>?
    @State private var isGenerating = false
    @State private var generationProgress: Double = 0
    // The transcription language is a per-machine preference, remembered
    // across launches and projects instead of being reset with the session.
    @AppStorage(AppPreferences.subtitleTranscriptionLanguageKey)
    private var selectedLanguageID = SubtitleTranscriptionService.automaticLanguageID

    private let service = SubtitleTranscriptionService()

    private struct LanguageOption: Identifiable, Hashable {
        let id: String
        let label: String
    }

    private static let languages: [LanguageOption] = [
        LanguageOption(id: SubtitleTranscriptionService.automaticLanguageID, label: "跟随界面"),
        LanguageOption(id: "zh-CN", label: "中文（普通话）"),
        LanguageOption(id: "yue-CN", label: "中文（粤语）"),
        LanguageOption(id: "en-US", label: "English (US)"),
        LanguageOption(id: "ja-JP", label: "日本語"),
        LanguageOption(id: "ko-KR", label: "한국어"),
    ]

    @State private var showsFindReplace = false
    @State private var findText = ""
    @State private var replaceText = ""

    private var cues: [SubtitleCue] {
        editorStore.previewProject.timeline.subtitleCues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            generationSection
            styleSection
            cuesSection
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        EditorInspectorSection("生成字幕", showsTitle: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Self.languages) { language in
                        Button(language.label) {
                            selectedLanguageID = language.id
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .globe, size: 13)
                        Text(languageLabel(selectedLanguageID))
                            .font(.appUI(size: 12))
                            .lineLimit(1)
                        EditorSymbol("chevron.up.chevron.down", size: 9)
                            .font(.appUI(size: 9, weight: .medium))
                    }
                    .foregroundStyle(EditorTheme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isGenerating)

                Spacer(minLength: 0)

                if isGenerating {
                    Button(role: .destructive) {
                        generationTask?.cancel()
                    } label: {
                        EditorSymbolLabel(appLocalized("取消"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.editorQuiet)
                } else if !cues.isEmpty {
                    Button {
                        startGeneration()
                    } label: {
                        EditorSymbolLabel(appLocalized("重新生成"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.editorQuiet)
                    .disabled(!canGenerate)
                }

                Button {
                    startGeneration()
                } label: {
                    EditorSymbolLabel(
                        appLocalized(cues.isEmpty ? "生成字幕" : "生成"),
                        systemImage: "waveform.badge.mic"
                    )
                }
                .buttonStyle(.editorPrimary)
                .disabled(!canGenerate)
            }

            if isGenerating {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: generationProgress)
                        .progressViewStyle(.linear)
                    Text(appLocalized("正在生成字幕…"))
                        .font(.appUI(size: 11))
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
            } else if !canGenerate {
                EditorInfoNote(
                    systemImage: "speaker.slash",
                    lines: [appLocalized("无可用音频，无法生成字幕")]
                )
            } else {
                EditorInfoNote(
                    systemImage: "info.circle",
                    lines: [appLocalized("字幕跟随剪辑：剪切、变速与重排后自动对齐。")]
                )
            }
        }
    }

    private var canGenerate: Bool {
        mediaSession.prepared != nil
            && (mediaSession.inventories.source.hasAudio
                || mediaSession.inventories.microphone.hasAudio)
    }

    private func languageLabel(_ id: String) -> String {
        let localized = Self.languages.first(where: { $0.id == id })?.label
        if id == SubtitleTranscriptionService.automaticLanguageID, let localized {
            return appLocalized(localized)
        }
        return localized ?? id
    }

    private func startGeneration() {
        guard let media = mediaSession.prepared?.composition, canGenerate else {
            onError(appLocalized("无可用音频，无法生成字幕"))
            return
        }
        let input = SubtitleTranscriptionInput(
            media: media,
            project: editorStore.project,
            localeIdentifier: SubtitleTranscriptionService.resolvedLocaleIdentifier(
                selected: selectedLanguageID
            )
        )
        isGenerating = true
        generationProgress = 0
        generationTask = Task { @MainActor in
            do {
                let cues = try await service.generateCues(input: input) { fraction in
                    Task { @MainActor in
                        generationProgress = fraction
                    }
                }
                if !Task.isCancelled {
                    try editorStore.setSubtitleCues(cues)
                }
            } catch is CancellationError {
                // The user cancelled; keep the previous captions untouched.
            } catch {
                let isCancelled = (error as? VideoExporterError) == .cancelled
                if !isCancelled {
                    onError(appLocalized("字幕生成失败") + "：\(error.localizedDescription)")
                }
            }
            isGenerating = false
        }
    }

    // MARK: - Style

    private var styleSection: some View {
        EditorInspectorSection("字幕样式") {
            HStack {
                Toggle(isOn: styleBinding(\.isEnabled, actionName: "在画面中显示字幕")) {
                    Text(appLocalized("在画面中显示字幕"))
                        .font(.appUI(size: 13))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer(minLength: 0)

                presetMenu
            }
            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: appLocalized("字号"),
                value: styleBinding(\.fontScale, actionName: "调整字幕字号"),
                range: 0.5...2.5,
                commandScope: .subtitle,
                format: .multiplier,
                onError: onError
            )
            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: appLocalized("底部边距"),
                value: styleBinding(\.baselineInset, actionName: "调整字幕底部边距"),
                range: 0.02...0.25,
                commandScope: .subtitle,
                format: .percent,
                onError: onError
            )
            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: appLocalized("遮罩不透明度"),
                value: styleBinding(\.backdropOpacity, actionName: "调整字幕遮罩不透明度"),
                range: 0...1,
                commandScope: .subtitle,
                format: .percent,
                onError: onError
            )

            styleChoiceRow(
                "字幕字体",
                options: SubtitleFontFamily.allCases,
                label: fontFamilyLabel,
                selection: styleBinding(\.fontFamily, actionName: "调整字幕字体")
            )

            styleChoiceRow(
                "位置",
                options: SubtitleAnchor.allCases,
                label: anchorLabel,
                selection: styleBinding(\.anchor, actionName: "调整字幕位置")
            )

            styleChoiceRow(
                "对齐",
                options: SubtitleTextAlignment.allCases,
                label: alignmentLabel,
                selection: styleBinding(\.textAlignment, actionName: "调整字幕对齐")
            )

            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: appLocalized("文字颜色"),
                value: styleBinding(\.textColor, actionName: "调整字幕文字颜色"),
                commandScope: .subtitle,
                actionName: "调整字幕文字颜色",
                onError: onError
            )

            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: appLocalized("描边宽度"),
                value: styleBinding(\.strokeWidth, actionName: "调整字幕描边宽度"),
                range: 0...0.15,
                commandScope: .subtitle,
                format: .percent,
                onError: onError
            )

            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: appLocalized("描边颜色"),
                value: styleBinding(\.strokeColor, actionName: "调整字幕描边颜色"),
                commandScope: .subtitle,
                actionName: "调整字幕描边颜色",
                onError: onError
            )

            EditorTransactionalSliderRow(
                editorStore: editorStore,
                title: appLocalized("阴影强度"),
                value: styleBinding(\.shadowOpacity, actionName: "调整字幕阴影强度"),
                range: 0...1,
                commandScope: .subtitle,
                format: .percent,
                onError: onError
            )

            Toggle(isOn: styleBinding(\.highlightEnabled, actionName: "字幕逐词高亮")) {
                Text(appLocalized("逐词高亮"))
                    .font(.appUI(size: 13))
                    .foregroundStyle(EditorTheme.secondaryText)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            EditorTransactionalColorInput(
                editorStore: editorStore,
                title: appLocalized("高亮颜色"),
                value: styleBinding(\.highlightColor, actionName: "调整字幕高亮颜色"),
                commandScope: .subtitle,
                actionName: "调整字幕高亮颜色",
                onError: onError
            )
        }
    }

    /// One-click caption looks plus the per-machine default management.
    private var presetMenu: some View {
        Menu {
            ForEach(SubtitleStylePreset.all) { preset in
                Button(appLocalized(preset.name)) { applyPreset(preset) }
            }
            Divider()
            Button(appLocalized("保存为默认")) { saveCurrentAsDefault() }
            Button(appLocalized("恢复默认样式")) { applyDefaultStyle() }
        } label: {
            HStack(spacing: 6) {
                EditorSymbol("paintpalette", size: 12)
                Text(appLocalized("预设"))
                    .font(.appUI(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(EditorTheme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(appLocalized("一键套用字幕样式"))
    }

    private func applyPreset(_ preset: SubtitleStylePreset) {
        do {
            try editorStore.replaceSubtitleStyle(
                with: editorStore.project.subtitleStyle.replacingVisuals(with: preset.style),
                actionName: "套用字幕预设"
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func saveCurrentAsDefault() {
        AppPreferences.rememberDefaultSubtitleStyle(editorStore.project.subtitleStyle)
    }

    private func applyDefaultStyle() {
        do {
            try editorStore.replaceSubtitleStyle(
                with: editorStore.project.subtitleStyle.replacingVisuals(
                    with: AppPreferences.defaultSubtitleStyle
                ),
                actionName: "恢复字幕默认样式"
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// A labeled segmented row: the caption parameters read as a name above a
    /// capsule switch, matching the neighboring slider rows.
    private func styleChoiceRow<Option: Hashable>(
        _ title: String,
        options: [Option],
        label: @escaping (Option) -> String,
        selection: Binding<Option>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
            EditorSegmentedControl(
                options: options,
                title: label,
                selection: selection
            )
        }
    }

    private func fontFamilyLabel(_ family: SubtitleFontFamily) -> String {
        switch family {
        case .system: "系统"
        case .rounded: "圆体"
        case .serif: "衬线"
        case .monospaced: "等宽"
        }
    }

    private func anchorLabel(_ anchor: SubtitleAnchor) -> String {
        switch anchor {
        case .top: "顶部"
        case .middle: "中部"
        case .bottom: "底部"
        }
    }

    private func alignmentLabel(_ alignment: SubtitleTextAlignment) -> String {
        switch alignment {
        case .leading: "左"
        case .center: "居中"
        case .trailing: "右"
        }
    }

    private func styleBinding<Value>(
        _ keyPath: WritableKeyPath<SubtitleStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorSubtitleBinding(
            store: editorStore,
            keyPath: keyPath,
            actionName: actionName,
            onError: onError
        )
    }

    // MARK: - Cue list

    private var cuesSection: some View {
        EditorInspectorSection("字幕内容") {
            HStack {
                Text(String(format: appLocalized("共 %lld 条"), cues.count))
                    .font(.appUI(size: 11))
                    .foregroundStyle(EditorTheme.tertiaryText)
                Spacer(minLength: 0)
                findReplaceButton
                importButton
                if !cues.isEmpty {
                    exportMenu
                    Button {
                        clearCues()
                    } label: {
                        EditorSymbol("trash", size: 13)
                            .foregroundStyle(EditorTheme.secondaryText)
                    }
                    .buttonStyle(.editorQuiet)
                    .help(appLocalized("清空字幕"))
                    .accessibilityLabel(appLocalized("清空字幕"))
                }
            }

            if showsFindReplace, !cues.isEmpty {
                findReplaceFields
            }

            if !cues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            SubtitleCueRow(
                                cue: cue,
                                canMergeWithNext: index < cues.count - 1,
                                onSeek: {
                                    playbackController.seek(to: cue.timing.startTime)
                                },
                                onTextCommit: { text in
                                    commitCueText(cue, text: text)
                                },
                                onTimingCommit: { start, end in
                                    commitCueTiming(cue, start: start, end: end)
                                },
                                onMerge: {
                                    mergeCue(cue)
                                },
                                onSplit: {
                                    splitCue(cue)
                                },
                                onDelete: {
                                    removeCue(cue)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else {
                EditorInfoNote(
                    systemImage: "text.bubble",
                    lines: [appLocalized("还没有字幕，可生成或导入字幕文件。")]
                )
            }
        }
    }

    private var findReplaceButton: some View {
        Button {
            showsFindReplace.toggle()
        } label: {
            EditorSymbol("magnifyingglass", size: 13)
                .foregroundStyle(EditorTheme.secondaryText)
        }
        .buttonStyle(.editorQuiet)
        .disabled(cues.isEmpty)
        .help(appLocalized("在全部字幕中查找替换"))
        .accessibilityLabel(appLocalized("查找"))
    }

    private var findReplaceFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(appLocalized("查找"), text: $findText)
                .textFieldStyle(.plain)
                .font(.appUI(size: 12))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    EditorChoiceStyle.track,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            HStack(spacing: 6) {
                TextField(appLocalized("替换"), text: $replaceText)
                    .textFieldStyle(.plain)
                    .font(.appUI(size: 12))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        EditorChoiceStyle.track,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                Button {
                    replaceAll()
                } label: {
                    EditorSymbolLabel(appLocalized("全部替换"), systemImage: "text.badge.checkmark")
                        .font(.appUI(size: 11))
                }
                .buttonStyle(.editorQuiet)
                .disabled(findText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func replaceAll() {
        let find = findText
        guard !find.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let hasMatch = cues.contains {
            $0.text.contains(find) || $0.words.contains { $0.text.contains(find) }
        }
        guard hasMatch else {
            onError(appLocalized("没有匹配的字幕。"))
            return
        }
        do {
            try editorStore.replaceSubtitleText(find: find, replacement: replaceText)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func mergeCue(_ cue: SubtitleCue) {
        do {
            try editorStore.mergeSubtitleCueWithNext(id: cue.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func splitCue(_ cue: SubtitleCue) {
        do {
            try editorStore.splitSubtitleCue(id: cue.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Import

    private var importButton: some View {
        Button {
            importSubtitles()
        } label: {
            EditorSymbol("square.and.arrow.down", size: 13)
                .foregroundStyle(EditorTheme.secondaryText)
        }
        .buttonStyle(.editorQuiet)
        .help(appLocalized("导入字幕文件"))
        .accessibilityLabel(appLocalized("导入"))
    }

    private func importSubtitles() {
        let panel = NSOpenPanel()
        panel.title = appLocalized("导入字幕文件")
        panel.prompt = appLocalized("导入")
        panel.allowedContentTypes = subtitleContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
                onError(appLocalized("无法读取字幕文件。"))
                return
            }
            let imported = SubtitleFileWriter.parse(text)
            guard !imported.isEmpty else {
                onError(appLocalized("没有解析到可导入的字幕。"))
                return
            }
            // Replacing the cue list is a single undoable edit (⌘Z restores
            // whatever was there before the import).
            try editorStore.setSubtitleCues(imported, actionName: "导入字幕")
        } catch {
            onError(error.localizedDescription)
        }
    }

    private var subtitleContentTypes: [UTType] {
        // The system assigns unregistered caption extensions a dynamic UTI
        // (e.g. dyn.ah62d4rv4ge81g6xy for .srt). Deriving a type with
        // `conformingTo:` mints a *different* dynamic identifier, so the real
        // file looks unmatched and is greyed out in the open panel. The plain
        // lookup returns the same identifier the panel resolves for the file.
        [SubtitleFileFormat.srt, SubtitleFileFormat.vtt].compactMap {
            UTType(filenameExtension: $0.fileExtension)
        }
    }

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            ForEach(SubtitleFileFormat.allCases, id: \.self) { format in
                Button(formatLabel(format)) { exportSubtitles(format) }
            }
        } label: {
            EditorSymbol("square.and.arrow.up", size: 13)
                .foregroundStyle(EditorTheme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(appLocalized("导出字幕文件"))
        .accessibilityLabel(appLocalized("导出字幕"))
    }

    private func formatLabel(_ format: SubtitleFileFormat) -> String {
        appLocalized(format == .srt ? "SRT 字幕文件" : "WebVTT 字幕文件")
    }

    private func exportSubtitles(_ format: SubtitleFileFormat) {
        let exportable = cues.filter(\.isRenderable)
        guard !exportable.isEmpty else {
            onError(appLocalized("没有可导出的字幕。"))
            return
        }
        let panel = NSSavePanel()
        panel.title = appLocalized("导出字幕文件")
        panel.prompt = appLocalized("导出")
        panel.nameFieldStringValue = suggestedSubtitleFileName(format)
        // Same dynamic-UTI reasoning as import: use the plain lookup so the
        // save panel recognizes the extension instead of a foreign identifier.
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = SubtitleFileWriter.serialize(cues: exportable, format: format)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Mirrors the video export naming policy: the project title, with path
    /// separators folded into dashes, and a localized fallback when untitled.
    private func suggestedSubtitleFileName(_ format: SubtitleFileFormat) -> String {
        let trimmed = editorStore.project.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = trimmed
            .components(separatedBy: forbidden)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = cleaned.isEmpty ? appLocalized("字幕") : cleaned
        return "\(base).\(format.fileExtension)"
    }

    private func commitCueText(_ cue: SubtitleCue, text: String) {
        do {
            try editorStore.updateSubtitleCue(id: cue.id, text: text)
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Retiming parks the playhead on the caption so the canvas shows exactly
    /// the interval that was just typed.
    private func commitCueTiming(
        _ cue: SubtitleCue,
        start: TimeInterval,
        end: TimeInterval
    ) {
        do {
            try editorStore.updateSubtitleCueTiming(
                id: cue.id,
                startTime: start,
                endTime: end
            )
            playbackController.seek(to: max(start, 0))
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func removeCue(_ cue: SubtitleCue) {
        do {
            try editorStore.removeSubtitleCue(id: cue.id)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func clearCues() {
        do {
            try editorStore.setSubtitleCues([], actionName: "清空字幕")
        } catch {
            onError(error.localizedDescription)
        }
    }
}

/// One caption row: a seek button on the recorded time, a vertically growing
/// text field committing on focus loss (Return inserts a line break so cues
/// can hold several lines, matching SRT/VTT), merge/split actions, and delete.
private struct SubtitleCueRow: View {
    let cue: SubtitleCue
    let canMergeWithNext: Bool
    let onSeek: () -> Void
    let onTextCommit: (String) -> Void
    let onTimingCommit: (TimeInterval, TimeInterval) -> Void
    let onMerge: () -> Void
    let onSplit: () -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @State private var isEditingDraft = false
    @FocusState private var isFieldFocused: Bool

    private var timeText: String {
        MotionInspectorLogic.timecode(cue.timing.startTime)
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { isEditingDraft ? draft : cue.text },
            set: { newValue in
                if !isEditingDraft {
                    isEditingDraft = true
                    draft = cue.text
                }
                draft = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onSeek) {
                    Text(timeText)
                        .font(.appUI(size: 11).monospacedDigit())
                        .foregroundStyle(EditorTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            EditorChoiceStyle.track,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(appLocalized("跳转到此字幕"))

                Spacer(minLength: 0)

                Button(action: onMerge) {
                    EditorSymbol("arrow.down.to.line", size: 12)
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .buttonStyle(.plain)
                .disabled(!canMergeWithNext)
                .help(appLocalized("合并到下一条"))

                Button(action: onSplit) {
                    EditorSymbol("rectangle.split.2x1", size: 12)
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .buttonStyle(.plain)
                .disabled(cue.text.count < 2)
                .help(appLocalized("在时间中点拆分"))

                Button(action: onDelete) {
                    AppLineIcon(kind: .trash, size: 13)
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help(appLocalized("删除字幕"))
            }

            TextField(appLocalized("字幕文本"), text: textBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.appUI(size: 12))
                .foregroundStyle(EditorTheme.primaryText)
                .lineLimit(1...4)
                .focused($isFieldFocused)
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused, isEditingDraft {
                        commitDraft()
                    }
                }

            HStack(spacing: 10) {
                SubtitleTimeField(title: "开始", time: cue.timing.startTime) { start in
                    onTimingCommit(start, cue.timing.endTime)
                }
                SubtitleTimeField(title: "结束", time: cue.timing.endTime) { end in
                    onTimingCommit(cue.timing.startTime, end)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            EditorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func commitDraft() {
        guard isEditingDraft else { return }
        isEditingDraft = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard text != cue.text else { return }
        if text.isEmpty {
            onDelete()
        } else {
            onTextCommit(text)
        }
    }
}

/// One editable timecode cell inside a caption row. Typing commits on Enter
/// or blur; text that does not parse as a time reverts to the stored value.
private struct SubtitleTimeField: View {
    let title: String
    let time: TimeInterval
    let onCommit: (TimeInterval) -> Void

    @State private var draft = ""
    @State private var isEditingDraft = false
    @FocusState private var isFocused: Bool

    private var binding: Binding<String> {
        Binding(
            get: { isEditingDraft ? draft : MotionInspectorLogic.timecode(time) },
            set: { newValue in
                if !isEditingDraft {
                    isEditingDraft = true
                    draft = MotionInspectorLogic.timecode(time)
                }
                draft = newValue
            }
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(appLocalized(title))
                .font(.appUI(size: 10))
                .foregroundStyle(EditorTheme.tertiaryText)
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.appUI(size: 11).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 78)
                .padding(.vertical, 3)
                .background(
                    EditorChoiceStyle.track,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused, isEditingDraft {
                        commit()
                    }
                }
                .accessibilityLabel(appLocalized(title))
        }
    }

    private func commit() {
        guard isEditingDraft else { return }
        isEditingDraft = false
        let text = draft
        draft = ""
        guard let seconds = MotionInspectorLogic.seconds(fromTimecode: text),
              abs(seconds - time) > 0.001
        else { return }
        onCommit(seconds)
    }
}
