#!/bin/bash
# Запуск загрузчика артефакта в фоне. Usage: ./launch.sh <artifact_id> <size_bytes>
cd /root/workspace/LxBox
export GITHUB_TOKEN=$(tr -d '\n\r' < /root/.hermes/.gh_token)
rm -rf /tmp/parart /tmp/apks-new.zip /tmp/artx
setsid nohup python3 scripts/dl_artifact.py "$1" "$2" mx57/LxBox > /root/workspace/dl_art.log 2>&1 &
echo "PID=$!  log=/root/workspace/dl_art.log"
