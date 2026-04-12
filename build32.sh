#!/bin/bash
# Build 32-bit artifacts only
set -e

docker compose build --no-cache build32

echo "Extracting 32-bit artifacts..."
rm -rf out32
mkdir -p out32

CID=$(docker create gmsv_execute_builder:32)
docker cp "$CID:/gmsv_execute_linux.dll"    ./out32/
docker cp "$CID:/git"                       ./out32/git32
docker cp "$CID:/git-libexec"               ./out32/git32-libexec
docker cp "$CID:/ssh"                       ./out32/ssh32
docker cp "$CID:/ssh-keygen"                ./out32/ssh-keygen32
docker rm "$CID" >/dev/null

echo "Done!"
ls -la out32/
