"""Platform packs.

The graph is platform-invariant; only these commands and idioms change. Adding
iOS/KMP/Flutter/React Native is a new PlatformPack, not a new pipeline — the
PM → Architect → Coder → Tester shape and both reviewer gates are identical.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class PlatformPack:
    key: str
    label: str
    build_cmd: str
    verify_cmd: str
    install_cmd: str
    ui_selector_idiom: str
    device_mcp: str
    conventions: str = ""
    file_globs: tuple[str, ...] = field(default_factory=tuple)

    def as_prompt(self) -> str:
        return "\n".join(
            [
                f"**Platform**: {self.label}",
                f"**Build**: `{self.build_cmd}`",
                f"**Verify (lint/static/unit)**: `{self.verify_cmd}`",
                f"**Install to device**: `{self.install_cmd}`",
                f"**UI selector idiom**: {self.ui_selector_idiom}",
                f"**Device driver (MCP)**: {self.device_mcp}",
                f"**Source globs**: {', '.join(self.file_globs) or 'n/a'}",
                "",
                self.conventions.strip(),
            ]
        ).strip()


ANDROID = PlatformPack(
    key="android",
    label="Android (Kotlin / Compose)",
    build_cmd="./gradlew assembleDebug",
    verify_cmd="./gradlew lint detekt testDebugUnitTest",
    install_cmd="./gradlew installDebug",
    ui_selector_idiom=(
        "Compose `Modifier.testTag(\"<feature>_<element>\")`; XML Views use "
        "`contentDescription` or `android:tag`"
    ),
    device_mcp="auto-mobile (mcp__auto-mobile__*)",
    file_globs=("**/*.kt", "**/*.kts", "**/AndroidManifest.xml"),
    conventions=(
        "Follow the project's MVI/ViewModel shape, Hilt DI style, and module layout. "
        "Declare dependency versions in `gradle/libs.versions.toml`."
    ),
)

IOS = PlatformPack(
    key="ios",
    label="iOS (Swift / SwiftUI)",
    build_cmd="xcodebuild -scheme App -destination 'generic/platform=iOS Simulator' build",
    verify_cmd="swiftlint && xcodebuild test -scheme AppTests -destination 'platform=iOS Simulator,name=iPhone 15'",
    install_cmd="xcrun simctl install booted build/Debug-iphonesimulator/App.app",
    ui_selector_idiom="SwiftUI `.accessibilityIdentifier(\"<feature>_<element>\")`",
    device_mcp="idb / XCUITest-backed MCP (auto-mobile is Android-only)",
    file_globs=("**/*.swift", "**/Info.plist"),
    conventions=(
        "Follow the project's SwiftUI + observable-state conventions. Dependencies "
        "are declared in Package.swift or the Xcode project's SPM section."
    ),
)

KMP = PlatformPack(
    key="kmp",
    label="Kotlin Multiplatform (shared + platform targets)",
    build_cmd="./gradlew assemble",
    verify_cmd="./gradlew lint detekt allTests",
    install_cmd="./gradlew installDebug",
    ui_selector_idiom="Compose Multiplatform `Modifier.testTag(\"<feature>_<element>\")`",
    device_mcp="auto-mobile (Android target); idb-backed MCP (iOS target)",
    file_globs=("**/commonMain/**/*.kt", "**/androidMain/**/*.kt", "**/iosMain/**/*.kt"),
    conventions=(
        "Put platform-agnostic logic in commonMain and use expect/actual only where "
        "a platform API is genuinely required. Never leak a platform type into commonMain."
    ),
)

FLUTTER = PlatformPack(
    key="flutter",
    label="Flutter (Dart)",
    build_cmd="flutter build apk --debug",
    verify_cmd="flutter analyze && dart format --set-exit-if-changed . && flutter test",
    install_cmd="flutter install",
    ui_selector_idiom="`Key(ValueKey('<feature>_<element>'))` on every interactive widget",
    device_mcp="auto-mobile (Android); idb-backed MCP (iOS)",
    file_globs=("lib/**/*.dart", "test/**/*.dart", "pubspec.yaml"),
    conventions="Follow the project's state-management choice (Bloc/Riverpod/Provider) consistently.",
)

REACT_NATIVE = PlatformPack(
    key="react-native",
    label="React Native (TypeScript)",
    build_cmd="npx react-native build-android --mode=debug",
    verify_cmd="npm run lint && npx tsc --noEmit && npm test",
    install_cmd="npx react-native run-android",
    ui_selector_idiom="`testID=\"<feature>_<element>\"` on every interactive element",
    device_mcp="auto-mobile (Android); idb-backed MCP (iOS)",
    file_globs=("src/**/*.ts", "src/**/*.tsx", "package.json"),
    conventions="Follow the project's navigation library and state-management conventions.",
)

REGISTRY: dict[str, PlatformPack] = {
    p.key: p for p in (ANDROID, IOS, KMP, FLUTTER, REACT_NATIVE)
}


def get(key: str) -> PlatformPack:
    try:
        return REGISTRY[key]
    except KeyError:
        raise KeyError(f"unknown platform {key!r}; known: {sorted(REGISTRY)}") from None
