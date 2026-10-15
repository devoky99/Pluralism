import Dispatch
import Synchronization

/// Blockierende Arbeit (Dateien, Prozesse, Sockets) außerhalb des Main Actors.
///
/// Die Arbeit läuft auf einer globalen Dispatch-Queue und nicht im Thread-Pool von Swift Concurrency,
/// weil sie den Thread blockiert (warten auf Prozesse, Sockets, Plattenzugriffe). Das Ergebnis muss
/// `Sendable` sein, weil es zurück zum Aufrufer wandert (siehe „Sendable Types“ im Swift-Buch).
enum Background {
    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                 _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
    }

    static func runThrowing<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                         _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}

/// Rückrufe aus Lesethreads und Systemrückrufen auf den Main Actor bringen,
/// in der Reihenfolge, in der sie ausgelöst wurden.
enum MainQueue {
    static func async(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }
}

/// Abbruch-Merker, den ein Hintergrundthread lesen und der Main Actor setzen darf.
final class CancellationFlag: Sendable {
    private let value = Atomic<Bool>(false)

    func cancel() {
        value.store(true, ordering: .relaxed)
    }

    var isCancelled: Bool {
        value.load(ordering: .relaxed)
    }
}
