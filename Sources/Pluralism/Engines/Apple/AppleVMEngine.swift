import AppKit
import Foundation
import PluralismCore
import PluralismNet
import Virtualization

/// Engine für Linux-ARM64-Gäste auf Apples Virtualization.framework.
/// Die VM läuft auf der Main-Queue (Standard von `VZVirtualMachine(configuration:)`),
/// dadurch kommen auch alle Rückmeldungen auf dem Hauptthread an.
final class AppleVMEngine: NSObject, VMEngine, VZVirtualMachineDelegate {
    let bundle: VMBundle
    private(set) var config: VMConfiguration

    var onStateChange: ((VMRunState) -> Void)?
    var onNotice: ((String) -> Void)?

    private(set) var state: VMRunState = .stopped {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    private var virtualMachine: VZVirtualMachine?
    private var vzConfiguration: VZVirtualMachineConfiguration?
    private weak var displayView: VZVirtualMachineView?
    /// Das vmnet-Netz muss leben, solange die VM läuft.
    private var network: VMNetwork?
    private(set) var activeNetwork: ActiveNetwork = .none

    init(bundle: VMBundle, config: VMConfiguration) {
        self.bundle = bundle
        self.config = config
        super.init()
    }

    func update(configuration: VMConfiguration) {
        config = configuration
    }

    var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: bundle.savedStateURL.path)
    }

    // MARK: Lebenszyklus

    func start() {
        guard virtualMachine == nil else { return }
        state = .starting
        do {
            let (network, active, notice) = makeNetwork()
            self.network = network
            activeNetwork = active
            if let notice {
                onNotice?(notice)
            }
            let configuration = try AppleConfigurationFactory.make(config: config, bundle: bundle, network: network)
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            vzConfiguration = configuration
            virtualMachine = vm
            displayView?.virtualMachine = vm
            if hasSavedState {
                restore(vm)
            } else {
                boot(vm)
            }
        } catch {
            virtualMachine = nil
            vzConfiguration = nil
            network = nil
            activeNetwork = .none
            state = .error(error.localizedDescription)
        }
    }

    private func boot(_ vm: VZVirtualMachine) {
        state = .starting
        vm.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.state = .running
            case .failure(let error):
                self.virtualMachine = nil
                self.state = .error("Start fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func restore(_ vm: VZVirtualMachine) {
        state = .restoring
        vm.restoreMachineStateFrom(url: bundle.savedStateURL) { [weak self] error in
            guard let self else { return }
            if let error {
                // Gesicherter Zustand passt nicht mehr (andere Hardware-Konfiguration,
                // neueres macOS, anderer Benutzer). Dann normal starten.
                try? FileManager.default.removeItem(at: self.bundle.savedStateURL)
                self.onNotice?("Der gesicherte Zustand konnte nicht geladen werden (\(error.localizedDescription)). Die VM startet neu.")
                self.virtualMachine = nil
                self.displayView?.virtualMachine = nil
                self.state = .stopped
                self.start()
                return
            }
            vm.resume { [weak self] result in
                guard let self else { return }
                try? FileManager.default.removeItem(at: self.bundle.savedStateURL)
                switch result {
                case .success:
                    self.state = .running
                case .failure(let error):
                    self.state = .error("Fortsetzen fehlgeschlagen: \(error.localizedDescription)")
                }
            }
        }
    }

    func requestShutdown() {
        guard let vm = virtualMachine else { return }
        if vm.canRequestStop {
            do {
                try vm.requestStop()
                state = .stopping
            } catch {
                onNotice?("Herunterfahren konnte nicht angefordert werden: \(error.localizedDescription)")
            }
        } else {
            forceStop()
        }
    }

    func forceStop() {
        guard let vm = virtualMachine else {
            state = .stopped
            return
        }
        guard vm.canStop else {
            onNotice?("Die VM kann gerade nicht ausgeschaltet werden.")
            return
        }
        state = .stopping
        vm.stop { [weak self] error in
            self?.didStop(error: error)
        }
    }

    func pause() {
        guard let vm = virtualMachine, vm.canPause else { return }
        vm.pause { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.onNotice?("Pausieren fehlgeschlagen: \(error.localizedDescription)")
            } else {
                self.state = .paused
            }
        }
    }

    func resume() {
        guard let vm = virtualMachine, vm.canResume else { return }
        vm.resume { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.onNotice?("Fortsetzen fehlgeschlagen: \(error.localizedDescription)")
            } else {
                self.state = .running
            }
        }
    }

    // MARK: Zustand sichern ("Anhalten")

    var supportsSuspend: Bool {
        guard let configuration = vzConfiguration else { return false }
        do {
            try configuration.validateSaveRestoreSupport()
            return true
        } catch {
            return false
        }
    }

    func suspend() {
        guard let vm = virtualMachine else { return }
        if let configuration = vzConfiguration {
            do {
                try configuration.validateSaveRestoreSupport()
            } catch {
                onNotice?("Diese VM kann ihren Zustand nicht sichern: \(error.localizedDescription). Tipp: In den Einstellungen unter Erweitert „Anhalten ermöglichen“ einschalten.")
                return
            }
        }
        let save = { [weak self] in
            guard let self else { return }
            self.state = .saving
            vm.saveMachineStateTo(url: self.bundle.savedStateURL) { [weak self] error in
                guard let self else { return }
                if let error {
                    try? FileManager.default.removeItem(at: self.bundle.savedStateURL)
                    self.onNotice?("Sichern fehlgeschlagen: \(error.localizedDescription)")
                    vm.resume { [weak self] _ in self?.state = .running }
                    return
                }
                vm.stop { [weak self] error in
                    self?.didStop(error: error)
                }
            }
        }
        if vm.state == .paused {
            save()
        } else {
            vm.pause { [weak self] result in
                if case .failure(let error) = result {
                    self?.onNotice?("Pausieren vor dem Sichern fehlgeschlagen: \(error.localizedDescription)")
                } else {
                    save()
                }
            }
        }
    }

    // MARK: Anzeige

    func makeDisplayView() -> NSView? {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = config.peripherals.captureSystemKeys
        view.automaticallyReconfiguresDisplay = config.display.autoResize
        view.virtualMachine = virtualMachine
        displayView = view
        return view
    }

    var displayHint: String? { nil }

    // MARK: Extras

    func sendCtrlAltDelete() {}

    var supportsHotPlug: Bool {
        virtualMachine != nil
    }

    /// Eigenes vmnet-Netz für die VM. Bei Fehlern: Apples NAT („Internet und Mac“) bzw. kein Netz („Nur Mac“).
    private func makeNetwork() -> (VMNetwork?, ActiveNetwork, String?) {
        switch config.network.mode {
        case .none:
            return (nil, .none, nil)
        case .nat, .hostOnly:
            guard let addressing = config.network.addressing else {
                return (nil, config.network.mode == .nat ? .fallback : .none, nil)
            }
            do {
                let network = try VMNetwork(mode: config.network.mode == .nat ? .shared : .hostOnly,
                                            addressing: addressing, guestMAC: config.network.macAddress)
                return (network, .vmnet(addressing), nil)
            } catch {
                if config.network.mode == .nat {
                    return (nil, .fallback, "Eigenes Netz (vmnet) nicht verfügbar: \(error.localizedDescription) Die VM nutzt Apples einfaches NAT.")
                }
                return (nil, .none, "Netz „Nur Mac“ nicht verfügbar: \(error.localizedDescription) Die VM startet ohne Netzwerk.")
            }
        }
    }

    func hotPlugImage(_ url: URL, completion: @escaping (Error?) -> Void) {
        guard let vm = virtualMachine, let controller = vm.usbControllers.first else {
            completion(PluralismError.message("Die VM läuft nicht oder hat keinen USB-Controller."))
            return
        }
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
            let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            controller.attach(device: device) { error in
                completion(error)
            }
        } catch {
            completion(error)
        }
    }

    func terminateImmediately() {
        // Die VM lebt im Prozess von Pluralism und endet mit ihm. Ein letzter Versuch,
        // sie ordentlich anzuhalten, schadet nicht.
        if let vm = virtualMachine, vm.canStop {
            vm.stop { _ in }
        }
    }

    // MARK: VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        didStop(error: nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        didStop(error: error)
    }

    private func didStop(error: Error?) {
        virtualMachine = nil
        vzConfiguration = nil
        network = nil
        activeNetwork = .none
        displayView?.virtualMachine = nil
        if let error {
            state = .error(error.localizedDescription)
        } else {
            state = .stopped
        }
    }
}
