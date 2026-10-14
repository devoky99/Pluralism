import Foundation

/// Lädt Treiber- und Werkzeug-Abbilder herunter (virtio-win, UTM-Gasttools).
final class DownloadService: ObservableObject {
    /// virtio-win (Red Hat/Fedora, BSD-Lizenz): ARM64-Treiber für Netzwerk, Speicher, Anzeige usw.
    static let virtioWinURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
    /// UTM-Gasttools (zlib-Lizenz): enthalten den ARM64-SPICE-Agent für die Zwischenablage.
    static let guestToolsURL = URL(string: "https://getutm.app/downloads/utm-guest-tools-latest.iso")!
    /// Offizielle Download-Seite von Microsoft für Windows 11 ARM64.
    static let windowsARMPageURL = URL(string: "https://www.microsoft.com/de-de/software-download/windows11arm64")!

    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pluralism/Downloads", isDirectory: true)
    }

    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    func isRunning(_ id: String) -> Bool { tasks[id] != nil }

    func download(id: String, from url: URL, fileName: String, completion: @escaping (URL) -> Void) {
        guard tasks[id] == nil else { return }
        let destination = DownloadService.downloadsDirectory.appendingPathComponent(fileName)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            var result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(PluralismError.message("Der Server antwortete mit Status \(http.statusCode)."))
            } else if let tempURL {
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(at: DownloadService.downloadsDirectory, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.moveItem(at: tempURL, to: destination)
                    result = .success(destination)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(PluralismError.message("Download ohne Datei beendet."))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks[id] = nil
                self.observations[id] = nil
                self.progress[id] = nil
                switch result {
                case .success(let url):
                    completion(url)
                case .failure(let error):
                    self.errors[id] = error.localizedDescription
                }
            }
        }
        observations[id] = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                if self?.tasks[id] != nil {
                    self?.progress[id] = value
                }
            }
        }
        tasks[id] = task
        progress[id] = 0
        errors[id] = nil
        task.resume()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        observations[id] = nil
        progress[id] = nil
    }
}
