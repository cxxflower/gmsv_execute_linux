#!/bin/bash
set -e

docker compose build --no-cache

echo "Extracting build artifacts..."
rm -rf out
mkdir -p out

# 64-bit
CID64=$(docker create gmsv_execute_builder:64)
docker cp "$CID64:/gmsv_execute_linux64.dll" ./out/
docker cp "$CID64:/git"                       ./out/git64
docker cp "$CID64:/git-libexec"               ./out/git64-libexec
docker cp "$CID64:/ssh"                       ./out/ssh64
docker cp "$CID64:/ssh-keygen"                ./out/ssh-keygen64
docker rm "$CID64" >/dev/null

# 32-bit
CID32=$(docker create gmsv_execute_builder:32)
docker cp "$CID32:/gmsv_execute_linux.dll" ./out/
docker cp "$CID32:/git"                    ./out/git32
docker cp "$CID32:/git-libexec"            ./out/git32-libexec
docker cp "$CID32:/ssh"                    ./out/ssh32
docker cp "$CID32:/ssh-keygen"             ./out/ssh-keygen32
docker rm "$CID32" >/dev/null

echo ""
echo "Done! Files in out/:"
ls -lh out/
echo ""
echo "Upload everything from out/ to your server's working directory (next to garrysmod/)."
echo "The addon will automatically fix permissions on first run — no chmod needed."
