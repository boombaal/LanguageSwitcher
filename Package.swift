// swift-tools-version:5.9
import PackageDescription

// Только для `swift test`: приложение собирается из LanguageSwitcher.xcodeproj.
// Те же исходники подключены как библиотека, чтобы логику скоринга можно было гонять без запуска .app.
let package = Package(
    name: "LanguageSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "LanguageSwitcherCore",
            path: "LanguageSwitcher",
            exclude: ["AppMain.swift", "ls_early.c", "Info.plist", "Lexicon"]
        ),
        .testTarget(
            name: "LanguageSwitcherCoreTests",
            dependencies: ["LanguageSwitcherCore"],
            path: "Tests/LanguageSwitcherCoreTests"
        ),
    ]
)
