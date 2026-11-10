#!/usr/bin/env bash
# Regenerates the committed protobuf code from proto/.
#   Go:    server/internal/wire/*.pb.go          (protoc-gen-go)
#   Swift: ios/Packages/WaypointsKit/Sources/WireProtocol/*.pb.swift (protoc-gen-swift)
# Needs: protoc, protoc-gen-go (go install google.golang.org/protobuf/cmd/protoc-gen-go@latest),
#        protoc-gen-swift (brew install swift-protobuf).
# Output is deterministic for a given toolchain, so rerunning on a clean tree leaves git clean.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

export PATH="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin:$HOME/go/bin:$PATH"

for tool in protoc protoc-gen-go protoc-gen-swift; do
  command -v "$tool" >/dev/null || { echo "proto.sh: $tool not found" >&2; exit 1; }
done

protos=(proto/waypoints/v1/*.proto)
go_out="server/internal/wire"
swift_out="ios/Packages/WaypointsKit/Sources/WireProtocol"

rm -f "$go_out"/*.pb.go
protoc -I proto \
  --go_out=server --go_opt=module=waypoints/server \
  "${protos[@]}"

mkdir -p "$swift_out"
rm -f "$swift_out"/*.pb.swift
protoc -I proto \
  --swift_out="$swift_out" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  "${protos[@]}"

echo "proto.sh: generated $go_out and $swift_out"
