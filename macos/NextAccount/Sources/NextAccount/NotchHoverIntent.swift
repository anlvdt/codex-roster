import CoreGraphics
import Foundation

/// Distinguishes a deliberate linger on the notch pill from a drive-by
/// horizontal sweep across the menu bar.
enum NotchHoverIntent {
    /// Pointer must stay nearly still this long before hover-open.
    static let stillnessDwellMilliseconds: Int = 280
    /// Abort if the pointer never settles (keeps sweeping / jiggling).
    static let settleTimeoutMilliseconds: Int = 1_200
    /// Sample interval while waiting for stillness.
    static let sampleIntervalMilliseconds: Int = 40
    /// Max travel from the entry point that still counts as lingering.
    /// Larger horizontal travel ⇒ drive-by across the pill.
    static let maxLingerTravel: CGFloat = 36
    /// Per-sample jitter that still counts as "still".
    static let stillnessEpsilon: CGFloat = 5

    enum SampleResult: Equatable {
        case keepWaiting
        case open
        case abortDriveBy
        case abortTimeout
    }

    struct Tracker {
        let origin: CGPoint
        private(set) var lastSample: CGPoint
        private(set) var stillAccumulatedMs: Int = 0
        private(set) var elapsedMs: Int = 0

        init(origin: CGPoint) {
            self.origin = origin
            self.lastSample = origin
        }

        mutating func ingest(
            _ point: CGPoint,
            intervalMs: Int = NotchHoverIntent.sampleIntervalMilliseconds
        ) -> SampleResult {
            elapsedMs += intervalMs

            let travelFromOrigin = hypot(point.x - origin.x, point.y - origin.y)
            if travelFromOrigin > NotchHoverIntent.maxLingerTravel {
                return .abortDriveBy
            }

            let step = hypot(point.x - lastSample.x, point.y - lastSample.y)
            if step <= NotchHoverIntent.stillnessEpsilon {
                stillAccumulatedMs += intervalMs
            } else {
                stillAccumulatedMs = 0
            }
            lastSample = point

            if stillAccumulatedMs >= NotchHoverIntent.stillnessDwellMilliseconds {
                return .open
            }
            if elapsedMs >= NotchHoverIntent.settleTimeoutMilliseconds {
                return .abortTimeout
            }
            return .keepWaiting
        }
    }
}
