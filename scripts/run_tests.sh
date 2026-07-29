#!/usr/bin/env bash
set -euo pipefail

shopt -s nullglob

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

python3 -m unittest discover -s tests -p 'test_*.py' -v

for test_file in tests/*_test.lua; do
  lua "$test_file"
done

for test_file in tests/*_test.js; do
  node "$test_file"
done
