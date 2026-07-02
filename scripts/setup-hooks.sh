#!/usr/bin/env bash
# One-shot: подключить .githooks/ как hooks path для этого репо.
# Запускать один раз после `git clone`.
#
# После этого `git commit` будет автоматически синхронизировать
# `app/pubspec.yaml` `version:` line с git state (см. §066).

set -euo pipefail

cd "$(dirname "$0")/.."

git config core.hooksPath .githooks
chmod +x .githooks/* scripts/sync-pubspec-version.sh

echo "✅ git hooks enabled (core.hooksPath = .githooks)"
echo "   pre-commit will sync app/pubspec.yaml on every git commit."
