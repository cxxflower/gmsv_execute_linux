#!/bin/bash
# Build 64-bit artifacts only
set -e

docker compose build --no-cache build64

echo "Extracting 64-bit artifacts..."
rm -rf out64
mkdir -p out64

CID=$(docker create gmsv_execute_builder:64)
docker cp "$CID:/gmsv_execute_linux64.dll"  ./out64/
docker cp "$CID:/git"                       ./out64/git64
docker cp "$CID:/git-libexec"               ./out64/git64-libexec
docker cp "$CID:/ssh"                       ./out64/ssh64
docker cp "$CID:/ssh-keygen"                ./out64/ssh-keygen64
docker rm "$CID" >/dev/null

echo "Done! Files in out64/:"
ls -lh out64/
echo ""
echo "Upload everything from out64/ to your server's working directory (next to garrysmod/)."
echo "The addon will automatically fix permissions on first run — no chmod needed."
