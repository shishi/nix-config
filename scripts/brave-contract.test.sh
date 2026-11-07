#!/usr/bin/env bash
set -euo pipefail
package=${1:?Brave package path required}
version=${2:?Expected stable version required}
test -x "$package/bin/brave"
test -r "$package/share/applications/brave-browser.desktop"
test -r "$package/share/applications/com.brave.Browser.desktop"
"$package/bin/brave" --version | grep -F -- "$version"
