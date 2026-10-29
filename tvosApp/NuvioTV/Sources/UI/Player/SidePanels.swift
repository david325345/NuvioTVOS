import SwiftUI

// MARK: - Panel kind

enum PlayerSidePanel: Equatable {
    case episodes
    case sources
    case chapters
}

// MARK: - Chrome

/// Right-anchored in-player side sheet (episodes / sources / chapters).
struct PlayerSidePanelChrome<Content: View>: View {
    let title: String
    var onExit: () -> Void = {}
    @ViewBuilder var content: Content

    private let panelCornerRadius: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            // Nothing is drawn beside the panel: any scrim here is laid out
            // inside the safe area (the chrome only ignores the trailing edge),
            // so it renders as a dimmed rectangle with visible seams at the
            // screen's left and bottom instead of a full-bleed wash.
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                content
                    .frame(maxHeight: .infinity)
            }
            .padding(28)
            .frame(width: 640, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .glassRoundedRect(cornerRadius: panelCornerRadius)
            }
            .overlay {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 28, x: -8, y: 0)
            .padding(.vertical, 32)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .trailing)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onExitCommand(perform: onExit)
    }
}

// MARK: - Row

struct PlayerPanelRow: View {
    let title: String
    var subtitle: String?
    var trailing: String?
    var selected: Bool = false
    var isFocused: Bool = false

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var rowCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isFocused ? .black.opacity(0.7) : .white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(isFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                    )
                    .fixedSize()
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}

// MARK: - Episodes

struct PlayerEpisodesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focusedID: String?

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var rowCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 18)
    }

    private var thumbCornerRadius: CGFloat {
        max(4, AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16) * 0.6)
    }

    private var episodes: [NuvioVideo] {
        viewModel.panelEpisodes
    }

    private var targetEpisodeId: String? {
        viewModel.panelCurrentEpisodeId ?? episodes.first?.id
    }

    var body: some View {
        PlayerSidePanelChrome(title: "Episodes", onExit: { viewModel.closeSidePanel() }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if episodes.isEmpty {
                            Button {} label: {
                                PlayerPanelRow(
                                    title: "Episodes unavailable",
                                    subtitle: "No episode list for this session.",
                                    isFocused: focusedID == "empty"
                                )
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedID, equals: "empty")
                            .id("empty")
                        } else {
                            ForEach(episodes) { episode in
                                let isCurrent = episode.id == viewModel.panelCurrentEpisodeId
                                Button {
                                    viewModel.selectEpisode(episode)
                                } label: {
                                    episodeRow(episode, isCurrent: isCurrent, isFocused: focusedID == episode.id)
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focusEffectDisabledIfAvailable()
                                .focused($focusedID, equals: episode.id)
                                .id(episode.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .focusSection()
                .onAppear {
                    scrollToTarget(proxy: proxy)
                }
            }
        }
    }

    private func scrollToTarget(proxy: ScrollViewProxy) {
        guard let target = targetEpisodeId else { return }
        DispatchQueue.main.async {
            focusedID = target
            proxy.scrollTo(target, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedID = target
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func episodeRow(_ episode: NuvioVideo, isCurrent: Bool, isFocused: Bool) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Color.white.opacity(0.08)
                if let thumb = episode.thumbnail, let url = URL(string: thumb) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                } else {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: thumbCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("S\(episode.season) E\(episode.episode)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                Text(episode.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent {
                    Text(L10n.string("player_now_playing", fallback: "Now Playing"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(isFocused ? .black.opacity(0.65) : .white.opacity(0.75))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .strokeBorder(isCurrent && !isFocused ? Color.white.opacity(0.35) : .clear, lineWidth: 2)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}

// MARK: - Sources

struct PlayerSourcesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focusedID: String?
    @State private var visibleSourceLimit: Int = 20
    @State private var didSeedSourceFocus = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var rowCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 18)
    }

    private var targetSourceId: String? {
        if let current = viewModel.availableSources.first(where: { viewModel.isCurrentSource($0) }) {
            return current.id
        }
        return viewModel.availableSources.first?.id
    }

    private var sourcesToShow: [NuvioStream] {
        Array(viewModel.availableSources.prefix(visibleSourceLimit))
    }

    private func loadMoreSources() {
        guard visibleSourceLimit < viewModel.availableSources.count else { return }
        visibleSourceLimit = min(visibleSourceLimit + 20, viewModel.availableSources.count)
    }

    private func ensureTargetSourceVisible() {
        if let target = targetSourceId,
           let index = viewModel.availableSources.firstIndex(where: { $0.id == target }) {
            if index >= visibleSourceLimit {
                visibleSourceLimit = max(visibleSourceLimit, index + 10)
            }
        }
    }

    var body: some View {
        let totalCount = viewModel.availableSources.count
        let displayedCount = sourcesToShow.count
        let hasMore = totalCount > displayedCount

        PlayerSidePanelChrome(title: "Sources", onExit: { viewModel.closeSidePanel() }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.isLoadingSources && sourcesToShow.isEmpty {
                            Button {} label: {
                                HStack(spacing: 14) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(focusedID == "loading" ? .black : .white)
                                    Text(L10n.string("player_searching_sources", fallback: "Searching sources…"))
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(focusedID == "loading" ? .black : .white.opacity(0.8))
                                }
                                .padding(.horizontal, 22)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                                        .fill(focusedID == "loading" ? Color.white : Color.white.opacity(0.07))
                                )
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedID, equals: "loading")
                            .id("loading")
                        } else if viewModel.availableSources.isEmpty {
                            Button {} label: {
                                PlayerPanelRow(
                                    title: L10n.string("player_no_sources_found", fallback: "No sources found"),
                                    subtitle: L10n.string("player_no_sources_found_subtitle", fallback: "None of your stream add-ons returned a link."),
                                    isFocused: focusedID == "empty"
                                )
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedID, equals: "empty")
                            .id("empty")
                        } else {
                            ForEach(sourcesToShow, id: \.id) { stream in
                                let selected = viewModel.isCurrentSource(stream)
                                Button {
                                    viewModel.selectSource(stream)
                                } label: {
                                    PlayerPanelRow(
                                        title: stream.panelTitle,
                                        subtitle: stream.panelSubtitle,
                                        trailing: stream.panelResolutionLabel,
                                        selected: selected,
                                        isFocused: focusedID == stream.id
                                    )
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focusEffectDisabledIfAvailable()
                                .focused($focusedID, equals: stream.id)
                                .id(stream.id)
                                .onAppear {
                                    if let index = sourcesToShow.firstIndex(where: { $0.id == stream.id }),
                                       index >= sourcesToShow.count - 4,
                                       hasMore {
                                        loadMoreSources()
                                    }
                                }
                            }

                            if hasMore {
                                HStack(spacing: 12) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                    Text(L10n.format("details_showing_sources_format", fallback: "Showing %1$d of %2$d sources…", displayedCount, totalCount))
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                                .onAppear {
                                    loadMoreSources()
                                }
                            } else if viewModel.isLoadingSources {
                                HStack(spacing: 14) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                    Text(L10n.string("player_searching_sources", fallback: "Searching sources…"))
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .focusSection()
                .onAppear {
                    didSeedSourceFocus = false
                    viewModel.loadSourcesIfNeeded()
                    if sourcesToShow.isEmpty && viewModel.isLoadingSources {
                        focusedID = "loading"
                    }
                    seedSourceFocus(proxy: proxy)
                }
                .onChange(of: viewModel.availableSources.map(\.id)) { _, sourceIDs in
                    guard !sourceIDs.isEmpty else { return }
                    seedSourceFocus(proxy: proxy)
                }
            }
        }
    }

    private func seedSourceFocus(proxy: ScrollViewProxy) {
        ensureTargetSourceVisible()
        guard targetSourceId != nil else { return }
        didSeedSourceFocus = true
        scrollToTarget(proxy: proxy)
    }

    private func scrollToTarget(proxy: ScrollViewProxy) {
        guard let target = targetSourceId else { return }
        DispatchQueue.main.async {
            focusedID = target
            proxy.scrollTo(target, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let target = targetSourceId else { return }
            focusedID = target
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}

// MARK: - Stream display helpers

private extension NuvioStream {
    var panelTitle: String {
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        if let filename, !filename.isEmpty { return filename }
        return "Stream"
    }

    var panelSubtitle: String {
        var parts: [String] = []
        if let addonName, !addonName.isEmpty { parts.append(addonName) }
        if let description, !description.isEmpty,
           description.caseInsensitiveCompare(panelTitle) != .orderedSame {
            parts.append(description)
        }
        if isDebridResolvable { parts.append("Debrid") }
        return parts.joined(separator: " · ")
    }

    var panelResolutionLabel: String? {
        let blob = [name, description, filename].compactMap { $0 }.joined(separator: " ").lowercased()
        if blob.contains("2160") || blob.contains("4k") || blob.contains("uhd") { return "4K" }
        if blob.contains("1080") { return "1080p" }
        if blob.contains("720") { return "720p" }
        if blob.contains("480") { return "480p" }
        return nil
    }
}

// MARK: - Chapters

/// The file's chapters: number (▶ on the one playing), name, start time,
/// Opening / Ending badges. The playing chapter shows how much of it is left.
/// Selecting a chapter jumps to its start.
struct PlayerChaptersPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// The playhead, so the playing chapter and its progress stay current.
    @ObservedObject var clock: PlaybackClock
    /// Chapter thumbnails as they load.
    @ObservedObject var thumbnails: ChapterThumbnailStore
    @FocusState private var focusedID: Int?

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var rowCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 18)
    }

    private var thumbCornerRadius: CGFloat {
        max(4, AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16) * 0.6)
    }

    private var chapters: [PlaybackChapter] {
        viewModel.chapters
    }

    /// Thumbnails only when the player can make stills for this stream.
    private var showsThumbnails: Bool {
        viewModel.canShowChapterThumbnails
    }

    private var currentIndex: Int? {
        PlaybackChapters.index(at: clock.position, in: chapters)
    }

    private var title: String {
        chapters.isEmpty
            ? L10n.string("player_chapters", fallback: "Chapters")
            : L10n.format("player_chapters_count", fallback: "Chapters (%d)", chapters.count)
    }

    var body: some View {
        PlayerSidePanelChrome(title: title, onExit: { viewModel.closeSidePanel() }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if chapters.isEmpty {
                            Button {} label: {
                                PlayerPanelRow(
                                    title: L10n.string("player_chapters_unavailable", fallback: "No chapters"),
                                    subtitle: L10n.string(
                                        "player_chapters_unavailable_subtitle",
                                        fallback: "This file has no chapter list."
                                    ),
                                    isFocused: focusedID == -1
                                )
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedID, equals: -1)
                            .id(-1)
                        } else {
                            let current = currentIndex
                            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                                Button {
                                    viewModel.seekToChapter(chapter)
                                    viewModel.closeSidePanel()
                                } label: {
                                    chapterRow(
                                        chapter,
                                        index: index,
                                        isCurrent: index == current,
                                        isFocused: focusedID == chapter.id
                                    )
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focusEffectDisabledIfAvailable()
                                .focused($focusedID, equals: chapter.id)
                                .id(chapter.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .focusSection()
                .onAppear {
                    scrollToTarget(proxy: proxy)
                    // The first open starts loading every chapter's still; it carries on
                    // after the panel closes, so the next open has them.
                    viewModel.startChapterThumbnails()
                }
            }
        }
    }

    /// Opens on the chapter that is playing.
    private func scrollToTarget(proxy: ScrollViewProxy) {
        let target = chapters.isEmpty ? -1 : chapters[currentIndex ?? 0].id
        DispatchQueue.main.async {
            focusedID = target
            proxy.scrollTo(target, anchor: .center)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedID = target
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func chapterRow(_ chapter: PlaybackChapter, index: Int, isCurrent: Bool, isFocused: Bool) -> some View {
        let kind = PlaybackChapters.kind(of: chapter, segments: viewModel.skipSegments)
        let primary: Color = isFocused ? .black : .white
        let secondary: Color = isFocused ? .black.opacity(0.55) : .white.opacity(0.55)

        return HStack(alignment: .center, spacing: 16) {
            if showsThumbnails {
                chapterThumbnail(chapter, index: index, isCurrent: isCurrent)
            } else {
                Group {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(primary)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(secondary)
                    }
                }
                .frame(width: 40, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(PlaybackChapters.displayName(chapter, index: index))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(PlayerTimeFormat.clock(chapter.startSeconds))
                        .font(.system(size: 18, weight: .medium).monospacedDigit())
                        .foregroundStyle(secondary)
                    if let kind {
                        Text(kind == .opening
                             ? L10n.string("player_chapter_opening", fallback: "Opening")
                             : L10n.string("player_chapter_ending", fallback: "Ending"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(kind.color))
                    }
                    if isCurrent {
                        Text(L10n.format(
                            "player_chapter_time_left",
                            fallback: "%@ left",
                            PlayerTimeFormat.clock(chapter.endSeconds - clock.position)
                        ))
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isFocused ? .black.opacity(0.7) : .white.opacity(0.8))
                    }
                }

                if isCurrent, chapter.durationSeconds > 0 {
                    let fraction = min(max((clock.position - chapter.startSeconds) / chapter.durationSeconds, 0), 1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(isFocused ? Color.black.opacity(0.15) : Color.white.opacity(0.2))
                            Capsule()
                                .fill(kind?.color ?? (isFocused ? Color.black.opacity(0.75) : Color.white))
                                .frame(width: geo.size.width * CGFloat(fraction))
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .strokeBorder(isCurrent && !isFocused ? Color.white.opacity(0.35) : .clear, lineWidth: 2)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    /// 16:9 still with the chapter number (▶ on the playing one) in the corner;
    /// a plain tile until the still arrives.
    private func chapterThumbnail(_ chapter: PlaybackChapter, index: Int, isCurrent: Bool) -> some View {
        let image = thumbnails.images[chapter.id]
        return ZStack(alignment: .bottomLeading) {
            Color.white.opacity(0.08)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 90)
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 160, height: 90)
            }

            Group {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(6)
        }
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: thumbCornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: image != nil)
    }
}
