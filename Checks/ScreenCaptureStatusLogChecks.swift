import Foundation

@main
struct ScreenCaptureStatusLogChecks {
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        let start = Date(timeIntervalSince1970: 100)
        let added = "0[outside of RPC]: screen capture added"
        let removed = "0[outside of RPC]: screen capture removed"

        expect(ScreenCaptureStatusLog.change(from: added) == true, "Recognizes capture start")
        expect(ScreenCaptureStatusLog.change(from: removed) == false, "Recognizes capture stop")
        expect(ScreenCaptureStatusLog.change(from: "unrelated status event") == nil, "Ignores unrelated events")
        expect(
            ScreenCaptureStatusLog.change(
                fromJSONLine: #"{"eventMessage":"\#(added)","subsystem":"com.apple.SkyLight"}"#
            ) == true,
            "Recognizes capture start from the NDJSON stream"
        )
        expect(
            ScreenCaptureStatusLog.latestState(
                from: [(start, added), (start.addingTimeInterval(1), removed)]
            ) == false,
            "The latest event determines the current state"
        )
        expect(
            ScreenCaptureStatusLog.latestState(
                from: [(start.addingTimeInterval(1), removed), (start, added)]
            ) == false,
            "Events are ordered by time before applying state"
        )
        expect(
            ScreenCaptureStatusLog.latestState(
                from: [(start, added)],
                startingWith: true
            ) == true,
            "A repeated start is idempotent"
        )
        expect(ScreenCaptureProtectionState.pending.hidesAmounts, "Pending status hides amounts")
        expect(ScreenCaptureProtectionState.active.hidesAmounts, "Active capture hides amounts")
        expect(ScreenCaptureProtectionState.unavailable.hidesAmounts, "Unavailable status fails closed")
        expect(!ScreenCaptureProtectionState.inactive.hidesAmounts, "Inactive status allows amounts")

        print("\(count)/\(count) screen capture log checks passed")
    }
}
