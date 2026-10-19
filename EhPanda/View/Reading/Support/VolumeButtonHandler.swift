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
        onPress?(newValue < baseVolume ? 1 : -1)
        resetVolume()
    }

    private func resetVolume() {
        ignoresChangesUntil = Date().addingTimeInterval(Self.resetSettleTime)
        setVolume(baseVolume)
        // Compare later presses against where the volume actually settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resetSettleTime) { [weak self] in
            guard let self, observation != nil else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            if actual >= Self.step / 2, actual <= 1 - Self.step / 2 {
                baseVolume = actual
            }
        }
    }

    private func setVolume(_ value: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}
