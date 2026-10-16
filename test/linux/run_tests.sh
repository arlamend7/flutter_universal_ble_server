#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ble_test_dir=$(mktemp -d)
trap 'rm -rf "$ble_test_dir"' EXIT
for suite in peripheral central; do
  "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -Wno-unused-parameter \
    -Itest/linux/support $(pkg-config --cflags gio-unix-2.0) \
    "test/linux/${suite}_test.cc" -o "$ble_test_dir/$suite" \
    $(pkg-config --libs gio-unix-2.0)
  "$ble_test_dir/$suite"
done
