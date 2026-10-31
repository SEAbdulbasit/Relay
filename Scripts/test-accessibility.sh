#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
if [ "${1:-}" != "--desktop" ]; then
    echo 'Running permission-free regression tests. Real desktop interaction is opt-in.'
    swift test --filter 'AccessibilityContractTests|ToolTests|ExecutorTests'
    echo 'For actual typing/clicking: build Relay, grant Accessibility to Relay, then Settings → Access → Run accessibility check.'
    echo 'Optional CLI integration: ./Scripts/test-accessibility.sh --desktop (the test runner also needs Accessibility).'
    exit 0
fi
./Scripts/build-app.sh debug
export RELAY_RUN_AX_TESTS=1
export RELAY_AX_FIXTURE_APP="$PWD/build/Relay.app/Contents/Resources/RelayAccessibilityFixture.app"
swift test --filter AccessibilityDesktopIntegrationTests
