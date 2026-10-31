import Foundation
import Combine
import SwiftUI

@MainActor
final class SceneViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var selectedTab: SceneTab = .scene
    @Published var availableTabs: [SceneTab] = [.scene, .info]
    /// Whether InSight is one of the tabs: only then does opening the panel start its recognition.
    @Published private(set) var includesScene = true
    @Published var snapshot: SceneSnapshot = .empty
    @Published var selectedDetailItem: SceneDetailItem? = nil
    @Published var focusedCardID: String? = nil
    
    // Metadata properties for Info tab
    @Published var infoTitle: String = ""
    @Published var infoYear: String? = nil
    @Published var infoOverview: String = ""
    @Published var infoRuntime: String? = nil
    @Published var nextEpisode: NuvioVideo? = nil
    @Published var playbackInfo: ScenePlaybackInfo? = nil
    
    @Published var castCandidates: [SceneCastCandidate] = []
    
    let coordinator: SceneCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    init(coordinator: SceneCoordinator) {
        self.coordinator = coordinator
        
        coordinator.$currentSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
            }
            .store(in: &cancellables)
            
        coordinator.$castCandidates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] candidates in
                self?.castCandidates = candidates
            }
            .store(in: &cancellables)
    }
    
    var isDetailVisible: Bool {
        selectedDetailItem != nil
    }
    
    var isAnime: Bool {
        coordinator.isAnime
    }
    
    func setMetadata(
        title: String,
        year: Int?,
        overview: String?,
        runtime: String?,
        nextEpisode: NuvioVideo?,
        playbackInfo: ScenePlaybackInfo? = nil
    ) {
        self.infoTitle = title
        self.infoYear = year.map(String.init)
        self.infoOverview = overview ?? ""
        if let runtime, !runtime.isEmpty {
            self.infoRuntime = runtime.contains("min") ? runtime : "\(runtime) min"
        } else {
            self.infoRuntime = nil
        }
        self.nextEpisode = nextEpisode
        if let playbackInfo {
            self.playbackInfo = playbackInfo
        }
    }

    /// The tabs to show, in order (see `PlayerPanelTabs`).
    func configureTabs(_ tabs: [SceneTab]) {
        availableTabs = tabs
        includesScene = tabs.contains(.scene)
    }
    
    func updatePlaybackInfo(_ playbackInfo: ScenePlaybackInfo) {
        self.playbackInfo = playbackInfo
    }
    
    /// Opens on `tab` when it is shown, else on the first tab.
    func open(tab: SceneTab? = nil) {
        let wanted = tab.flatMap { availableTabs.contains($0) ? $0 : nil }
        guard !isVisible else {
            if let wanted { selectedTab = wanted }
            return
        }
        isVisible = true
        selectedTab = wanted ?? availableTabs.first ?? .scene
        if includesScene { coordinator.openPanel() }
    }
    
    func close() {
        guard isVisible else { return }
        isVisible = false
        selectedDetailItem = nil
        focusedCardID = nil
        coordinator.closePanel()
    }
    
    func selectTab(_ tab: SceneTab) {
        selectedTab = tab
    }
    
    func openDetail(_ item: SceneDetailItem) {
        selectedDetailItem = item
        if case .actor(let actor, let detail) = item, detail == nil, let tmdbId = actor.tmdbId {
            Task { [weak self] in
                guard let self else { return }
                let fetchedDetail = await self.coordinator.fetchPersonDetail(personId: tmdbId)
                await MainActor.run {
                    if case .actor(let curActor, _) = self.selectedDetailItem, curActor.id == actor.id {
                        self.selectedDetailItem = .actor(curActor, detail: fetchedDetail)
                    }
                }
            }
        }
    }
    
    func closeDetail() {
        selectedDetailItem = nil
    }
}
