#!/bin/bash
# Switch shell.xcodeproj between the upstream Swift packages (default) and the
# local xcframework override in .local-packages/ShellBinaries.
#
#   ./scripts/use-local-frameworks.sh on    # build offline / without SwiftPM auth
#   ./scripts/use-local-frameworks.sh off   # restore the upstream packages
#
# Run ./scripts/fetch-frameworks.sh first when switching on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/shell.xcodeproj/project.pbxproj"
MODE="${1:-}"

REMOTE_BLOCK='/* Begin XCRemoteSwiftPackageReference section */
		AB00000000000000000050 /* XCRemoteSwiftPackageReference "ghosttykit-rootshell" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/kitknox/ghosttykit-rootshell.git";
			requirement = {
				kind = exactVersion;
				version = 0.2.8;
			};
		};
		AB00000000000000000051 /* XCRemoteSwiftPackageReference "Citadel-rootshell" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/kitknox/Citadel-rootshell.git";
			requirement = {
				kind = exactVersion;
				version = 0.12.3;
			};
		};
		AB00000000000000000052 /* XCRemoteSwiftPackageReference "ios_system-rootshell" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/kitknox/ios_system-rootshell.git";
			requirement = {
				kind = exactVersion;
				version = 0.1.0;
			};
		};
/* End XCRemoteSwiftPackageReference section */'

LOCAL_BLOCK='/* Begin XCLocalSwiftPackageReference section */
		AB00000000000000000056 /* XCLocalSwiftPackageReference ".local-packages/ShellBinaries" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ".local-packages/ShellBinaries";
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCRemoteSwiftPackageReference section */
		AB00000000000000000051 /* XCRemoteSwiftPackageReference "Citadel-rootshell" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/kitknox/Citadel-rootshell.git";
			requirement = {
				kind = exactVersion;
				version = 0.12.3;
			};
		};
/* End XCRemoteSwiftPackageReference section */'

REMOTE_REFS='			packageReferences = (
				AB00000000000000000050 /* XCRemoteSwiftPackageReference "ghosttykit-rootshell" */,
				AB00000000000000000051 /* XCRemoteSwiftPackageReference "Citadel-rootshell" */,
				AB00000000000000000052 /* XCRemoteSwiftPackageReference "ios_system-rootshell" */,
			);'

LOCAL_REFS='			packageReferences = (
				AB00000000000000000056 /* XCLocalSwiftPackageReference ".local-packages/ShellBinaries" */,
				AB00000000000000000051 /* XCRemoteSwiftPackageReference "Citadel-rootshell" */,
			);'

REMOTE_GHOSTTY='		AB00000000000000000053 /* GhosttyKitAppStore */ = {
			isa = XCSwiftPackageProductDependency;
			package = AB00000000000000000050 /* XCRemoteSwiftPackageReference "ghosttykit-rootshell" */;
			productName = GhosttyKitAppStore;
		};'

LOCAL_GHOSTTY='		AB00000000000000000053 /* GhosttyKitAppStore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = GhosttyKitAppStore;
		};'

REMOTE_IOSSYS='		AB00000000000000000055 /* ios_system */ = {
			isa = XCSwiftPackageProductDependency;
			package = AB00000000000000000052 /* XCRemoteSwiftPackageReference "ios_system-rootshell" */;
			productName = ios_system;
		};'

LOCAL_IOSSYS='		AB00000000000000000055 /* ios_system */ = {
			isa = XCSwiftPackageProductDependency;
			productName = ios_system;
		};'

case "$MODE" in
    on)  FROM=("$REMOTE_BLOCK" "$REMOTE_REFS" "$REMOTE_GHOSTTY" "$REMOTE_IOSSYS")
         TO=("$LOCAL_BLOCK" "$LOCAL_REFS" "$LOCAL_GHOSTTY" "$LOCAL_IOSSYS") ;;
    off) FROM=("$LOCAL_BLOCK" "$LOCAL_REFS" "$LOCAL_GHOSTTY" "$LOCAL_IOSSYS")
         TO=("$REMOTE_BLOCK" "$REMOTE_REFS" "$REMOTE_GHOSTTY" "$REMOTE_IOSSYS") ;;
    *)   echo "usage: $0 on|off" >&2; exit 2 ;;
esac

python3 - "$PROJECT" "$MODE" "${FROM[@]}" "${TO[@]}" <<'PY'
import sys
path, mode = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
half = len(rest) // 2
pairs = list(zip(rest[:half], rest[half:]))

text = open(path).read()
for old, new in pairs:
    if new in text:
        continue
    if old not in text:
        sys.exit(f"error: project is not in the expected state for '{mode}'")
    text = text.replace(old, new, 1)
open(path, "w").write(text)
print(f"local frameworks: {mode}")
PY
