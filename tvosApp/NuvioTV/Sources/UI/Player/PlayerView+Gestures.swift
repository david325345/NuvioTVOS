import SwiftUI

/// Remote gestures during playback (fork test build): while playing with the controls hidden, the
/// gesture layer holds the remote. A bound gesture does its action; any other gesture does what
/// the player does with it anyway (± seek, hold seek, pause, controls, InSight, peek).
extension PlayerView {
    /// When the focus sink owns the remote (controls hidden, nothing else up).
    var isFocusSinkEligible: Bool {
        didReportPlaybackStarted
            && (!viewModel.showControls || viewModel.isSwitchingSource || viewModel.showPauseOverlay)
            && !viewModel.isScrubbing
            && !viewModel.isHoldingSeek
            && viewModel.currentErrorDiagnostic == nil
            && !viewModel.showNextEpisodeCard
            && !viewModel.showSkipSegmentCard
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    /// Gestures on, playing, the controls hidden and nothing else on screen. A hold seek the
    /// layer started keeps it until the button is released. The short wait after a seek (a
    /// chapter jump) keeps it too: dropping it there handed the remote to the focus sink.
    var isGestureCaptureActive: Bool {
        viewModel.areGesturesEnabled
            && didReportPlaybackStarted
            && !isWakingFromBackground
            && !isLoadingOverlayVisible
            && PlayerGestureCaptureStatus.keepsCapture(viewModel.status)
            && !viewModel.showControls
            && !viewModel.showPauseOverlay
            && !viewModel.isScrubbing
            && !viewModel.isSwitchingSource
            && viewModel.currentErrorDiagnostic == nil
            && !viewModel.showNextEpisodeCard
            && !viewModel.showSkipSegmentCard
            && !viewModel.showSettingsPanel
            && !viewModel.showScenePanel
            && !viewModel.isSceneDetailVisible
            && !viewModel.postPlayState.isVisible
            && viewModel.sidePanel == nil
    }

    var gestureCaptureLayer: some View {
        PlayerGestureCapture(
            isActive: isGestureCaptureActive,
            waitsForDouble: { double in
                PlayerGestureSettings.bindings().action(for: double) != nil
            },
            onGesture: handleRemoteGesture,
            onPressEnded: handleRemoteGesturePressEnded,
            onBack: handleRemoteBack,
            setPadObserver: { observer in
                viewModel.gesturePadObservers["player"] = observer
            },
            tuning: viewModel.gestureTuning
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            viewModel.isGestureCaptureActive = isGestureCaptureActive
        }
        .onChange(of: isGestureCaptureActive) { _, active in
            viewModel.isGestureCaptureActive = active
            if active {
                // The sink can't be focused now; a pending request for it would fight this layer.
                remoteInputFocused = false
            } else if isFocusSinkEligible, !viewModel.showControls {
                // Paused or otherwise left with nothing to take the remote: the sink takes it again.
                focusRemoteInput()
            }
        }
    }

    func handleRemoteGesture(_ gesture: RemoteGesture) {
        if let action = PlayerGestureSettings.bindings().action(for: gesture) {
            viewModel.performGestureAction(action)
            return
        }
        switch PlayerBuiltInGesture.action(for: gesture) {
        case .seekBack:
            viewModel.handleMoveSeek(direction: .left)
        case .seekForward:
            viewModel.handleMoveSeek(direction: .right)
        case .holdSeekBack:
            viewModel.gestureHoldSeekButton = .left
            viewModel.beginRepeatingSkipBackward()
        case .holdSeekForward:
            viewModel.gestureHoldSeekButton = .right
            viewModel.beginRepeatingSkipForward()
        case .select:
            viewModel.handleSelectTap()
        case .playPause:
            viewModel.togglePlayPause()
        case .revealControls:
            viewModel.revealControls()
        case .openPanel:
            if viewModel.isSceneEnabled {
                viewModel.openScene()
            } else {
                viewModel.revealControls()
            }
        case .peek:
            viewModel.showPeek()
        case nil:
            break
        }
    }

    func handleRemoteGesturePressEnded(_ button: RemoteButton) {
        guard viewModel.gestureHoldSeekButton == button else { return }
        viewModel.gestureHoldSeekButton = nil
        viewModel.stopRepeatingSkip()
    }
}

/// Which playback states the gesture layer holds the remote in.
enum PlayerGestureCaptureStatus {
    /// Playing, or the brief buffering after a seek. Paused, ended or failed hand the remote back.
    static func keepsCapture(_ status: PlayerStatus) -> Bool {
        switch status {
        case .playing, .buffering: return true
        case .idle, .paused, .ended, .error: return false
        }
    }
}
