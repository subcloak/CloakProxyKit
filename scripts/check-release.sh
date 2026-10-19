#!/bin/bash
# Checks that a Release build of CloakProxyKit contains none of the URLSession internals the recording code uses:
# runs the tests in both configurations, then looks for the private names in the compiled Release library.
#   scripts/check-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PRIVATE=(__NSCFURLLocalSessionConnection _didReceiveResponse:sniff: _didReceiveData: _didFinishWithError:
         _incompleteTaskMetrics _uploadTaskWithRequest:fromData:delegate:completionHandler:)

echo "Debug tests"
swift test
echo "Release tests"
swift test -c release -Xswiftc -enable-testing

echo "Release library"
swift build -c release --product CloakProxyKit
LIBRARY=.build/release/libCloakProxyKit.a
[ -f "$LIBRARY" ] || { echo "No Release library at $LIBRARY" >&2; exit 1; }
found=0
for name in "${PRIVATE[@]}"; do
    if strings -a "$LIBRARY" | grep -qF -- "$name"; then
        echo "FAIL: the Release build contains $name" >&2
        found=1
    fi
done
[ "$found" = 0 ] || exit 1
echo "OK: the Release build contains none of the private URLSession names."
