//
//  VolumeButtonHandler.swift
//  EhPanda
//

import SwiftUI
import MediaPlayer
import AVFoundation

/// Turns hardware volume button presses into page offsets (+1 for down, -1 for up)
/// by observing `outputVolume` and resetting it after each press.
final class VolumeButtonHandler: ObservableObject {
    private static let step: Float = 1 / 16
    private static let resetSettleTime: TimeInterval = 0.15

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var originalVolume: Float?
    private var baseVolume: Float = 0.5
    private var ignoresChangesUntil = Date.distantPast
    private var onPress: ((Int) -> Void)?

    deinit {
        observation?.invalidate()
        volumeView?.removeFromSuperview()
    }

    func start(onPress: @escaping (Int) -> Void) {
        self.onPress = onPress
        guard observation == nil else { return }
        Logger.info("start")

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            Logger.error("Failed to activate audio session", context: ["error": error])
            return
        }

        // An MPVolumeView in the window hides the system volume HUD and lets us set the volume.
        let view = MPVolumeView(frame: .init(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.01
        (DeviceUtil.keyWindow ?? DeviceUtil.anyWindow)?.addSubview(view)
        volumeView = view

        // Keep away from 0 and 1 so presses in both directions still change the volume.
        let current = session.outputVolume
        originalVolume = current
        baseVolume = min(max(current, Self.step), 1 - Self.step)
        if baseVolume != current {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                setVolume(baseVolume)
            }
        }

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            DispatchQueue.main.async { self?.handleVolumeChange(newValue) }
        }
    }

    func stop() {
        guard observation != nil else { return }
        Logger.info("stop")
        observation?.invalidate()
        observation = nil
        onPress = nil
        if let originalVolume, originalVolume != baseVolume {
            setVolume(originalVolume)
        }
        originalVolume = nil
        let view = volumeView
        volumeView = nil
        // Give the restore a moment before the HUD-hiding view goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            view?.removeFromSuperview()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func handleVolumeChange(_ newValue: Float) {
        // Our own reset can land slightly off the base volume; don't count it as a press.
        guard Date() >= ignoresChangesUntil,
              abs(newValue - baseVolume) > 0.001
        else { return }
        Logger.info("press", context: ["volume": newValue, "base": baseVolume])
        onPress?(newValue < baseVolume ? 1 : -1)
        resetVolume()
    }

    private func resetVolume(attempt: Int = 0) {
        ignoresChangesUntil = Date().addingTimeInterval(Self.resetSettleTime)
        setVolume(baseVolume)
        // Retry if the reset didn't take, otherwise the volume drifts to 0 or 1 and presses stop registering.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resetSettleTime) { [weak self] in
            guard let self, observation != nil else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            if abs(actual - baseVolume) < Self.step / 2 {
                baseVolume = actual
            } else if attempt < 2 {
                Logger.info("reset retry", context: ["volume": actual, "base": baseVolume])
                resetVolume(attempt: attempt + 1)
            }
        }
    }

    private func setVolume(_ value: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // The hidden slider doesn't track hardware presses; setting its stale value again is a no-op.
        if abs(slider.value - value) < 0.001 {
            slider.setValue(value > 0.5 ? value - 0.01 : value + 0.01, animated: false)
        }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}
