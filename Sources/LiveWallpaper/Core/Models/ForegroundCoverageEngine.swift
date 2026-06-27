import Foundation

struct ForegroundCoverageAppState: Equatable {
    let pid: pid_t
    let bundleID: String?
    let isFinder: Bool
}

enum ForegroundCoverageProbe: Equatable {
    case unavailable
    case uncertain
    case clear
    case covered(Set<String>)

    var coveredDisplayIDs: Set<String>? {
        if case let .covered(displayIDs) = self {
            return displayIDs
        }
        return nil
    }
}

struct ForegroundCoverageSnapshot: Equatable {
    let app: ForegroundCoverageAppState?
    let targetDisplayIDs: Set<String>
    let axProbe: ForegroundCoverageProbe
    let cgProbe: ForegroundCoverageProbe
}

enum ForegroundCoverageEngine {
    static func suspendedDisplayIDs(
        mode: SuspendDetectionMode,
        snapshot: ForegroundCoverageSnapshot
    ) -> Set<String> {
        guard let app = snapshot.app else {
            return []
        }

        switch mode {
        case .frontmostAppPresence:
            return app.isFinder ? [] : snapshot.targetDisplayIDs
        case .preciseWindowCoverage:
            return preciseSuspendedDisplayIDs(app: app, snapshot: snapshot)
        }
    }

    private static func preciseSuspendedDisplayIDs(
        app: ForegroundCoverageAppState,
        snapshot: ForegroundCoverageSnapshot
    ) -> Set<String> {
        if let covered = snapshot.axProbe.coveredDisplayIDs, !covered.isEmpty {
            return covered
        }
        if let covered = snapshot.cgProbe.coveredDisplayIDs {
            return covered
        }

        if app.isFinder {
            return []
        }

        if snapshot.axProbe == .clear {
            return []
        }

        if snapshot.axProbe == .uncertain || snapshot.cgProbe == .uncertain {
            return snapshot.targetDisplayIDs
        }

        return []
    }
}
