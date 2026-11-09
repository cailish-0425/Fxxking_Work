// swift-tools-version: 6.0
import PackageDescription

// Sparkle 的 framework 不入库：先跑 `./Scripts/fetch-sparkle.sh` 把它取到
// `.build/sparkle/2.10.1/Sparkle.framework`，下面的搜索路径才存在。
// 没取到时会明确报 "framework 'Sparkle' not found"，而不是悄悄编出一个没有更新器的包。
let sparkleFrameworkPath = ".build/sparkle/2.10.1"

let package = Package(
    name: "Fxxking_Work",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fxxking_Work",
            path: "Sources/Fxxking_Work",
            swiftSettings: [
                .unsafeFlags(["-F", sparkleFrameworkPath])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", sparkleFrameworkPath,
                    "-framework", "Sparkle",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        )
    ]
)
