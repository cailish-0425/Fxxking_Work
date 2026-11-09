import Foundation
import Sparkle

// Compare with the same comparator used by the installed updater.
let args = CommandLine.arguments
precondition(args.count >= 3, "Expected new version and at least one previous version")
let comparator = SUStandardVersionComparator()
for previous in args.dropFirst(2) {
    guard comparator.compareVersion(args[1], toVersion: previous) == .orderedDescending else {
        fputs("Release version must be newer than every previous feed item\n", stderr)
        exit(1)
    }
}
print("Release version is newer than the previous feed")
