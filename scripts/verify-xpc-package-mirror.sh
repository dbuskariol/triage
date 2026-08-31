#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

# SwiftPM's Triage target already owns CopilotXPCInterface.swift. A second
# SwiftPM target for the XPC executable would overlap that source, which SwiftPM
# rejects, while moving it would change the Xcode bundle's source boundary.
# Typecheck the exact XPC executable sources without weakening either build
# layout. XCTest assertion macros are only imported by Xcode's test compiler,
# so parse the existing fail-closed test source here; the Xcode test action
# remains responsible for compiling and executing those assertions.
/usr/bin/xcrun swiftc -typecheck -sdk "$SDK_PATH" \
  "$ROOT_DIR/Triage/CopilotXPC/CopilotXPCInterface.swift" \
  "$ROOT_DIR/TriageCopilotXPC/CopilotHelperProcess.swift" \
  "$ROOT_DIR/TriageCopilotXPC/CopilotXPCCallerValidator.swift" \
  "$ROOT_DIR/TriageCopilotXPC/CopilotXPCFrame.swift" \
  "$ROOT_DIR/TriageCopilotXPC/TriageCopilotXPCListener.swift" \
  "$ROOT_DIR/TriageCopilotXPC/TriageCopilotXPCService.swift" \
  "$ROOT_DIR/TriageCopilotXPC/main.swift"
/usr/bin/xcrun swiftc -parse \
  "$ROOT_DIR/TriageCopilotXPCTests/TriageCopilotXPCFailClosedTests.swift"
