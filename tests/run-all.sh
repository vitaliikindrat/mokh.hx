#!/bin/sh
# Pure-Scheme tests; need `steel` on PATH (pkgs.steel). The helix-facing
# code is exercised by the headless editor test in bridge/examples.
set -e
cd "$(dirname "$0")/.."
steel tests/util-test.scm
