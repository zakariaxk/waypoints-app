# Build gate and codegen entry points (docs/PLAN.md section 12).
#
#   make build      the only gate: Go build and vet, then the iOS app for the simulator
#   make generate   regenerate ios/Waypoints.xcodeproj from ios/project.yml
#   make run        build, install, and launch in the iPhone 16 simulator
#   make proto      regenerate wire types (script arrives with W0-B)
#   make bench-local  single-node benchmark (plan 8.3)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

GO_MODULES   := server tools/catalog
DERIVED_DATA := $(CURDIR)/.build/DerivedData
DESTINATION  := generic/platform=iOS Simulator
SIMULATOR    ?= iPhone 16
BUNDLE_ID    := app.waypoints.ios
CONFIG       := ios/App/Config.xcconfig
CATALOG      := ios/App/Resources/catalog.sqlite.lzfse

.PHONY: build go ios generate run proto clean bench-local bench-cluster

build: go ios

go:
	@for dir in $(GO_MODULES); do \
		if [ -f $$dir/go.mod ]; then \
			echo "==> go build and vet in $$dir"; \
			(cd $$dir && go build ./... && go vet ./...); \
		else \
			echo "==> skip $$dir (no go.mod yet)"; \
		fi; \
	done

$(CONFIG):
	cp ios/App/Config.example.xcconfig $@

# The bundled vehicle catalog snapshot (GAR-7), built from tools/catalog's download cache
# when missing. Untracked; delete it to rebuild after editing overrides.csv or supplement.csv.
$(CATALOG):
	@echo "==> catalog snapshot"
	@cd tools/catalog && go run . -cache .cache -out '$(CURDIR)/$(CATALOG)'

generate: $(CONFIG) $(CATALOG)
	@echo "==> xcodegen generate"
	@cd ios && xcodegen generate --quiet

# Swift 6 language mode turns concurrency diagnostics into errors in every target.
ios: generate
	@echo "==> xcodebuild ($(DESTINATION))"
	@cd ios && xcodebuild -project Waypoints.xcodeproj -scheme Waypoints \
		-destination '$(DESTINATION)' -derivedDataPath '$(DERIVED_DATA)' \
		-skipPackagePluginValidation -quiet build

run: generate
	@cd ios && xcodebuild -project Waypoints.xcodeproj -scheme Waypoints \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' -derivedDataPath '$(DERIVED_DATA)' -quiet build
	@xcrun simctl boot '$(SIMULATOR)' 2>/dev/null || true
	@open -a Simulator
	@xcrun simctl install '$(SIMULATOR)' '$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Waypoints.app'
	@xcrun simctl launch '$(SIMULATOR)' $(BUNDLE_ID)

proto:
	@if [ -x tools/proto.sh ]; then tools/proto.sh; else echo "tools/proto.sh not present yet (W0-B)"; exit 1; fi

# Benchmark I on this machine (plan 8.3). Writes bench/results and docs/BENCHMARKS.md.
bench-local:
	bench/run-local.sh

# Benchmark II: two nodes and NATS on this machine (needs nats-server).
bench-cluster:
	bench/run-cluster.sh

# W8-2: Release archive for App Store Connect. Config.xcconfig must point at the hosted
# backend and set LINK_HOST (docs/APP_STORE.md, Release build). Signing uses the team in
# Xcode's accounts; pass DEVELOPMENT_TEAM=<id> if the project does not set one.
# `make screenshots` runs tools/screenshots/shots.sh (CMP-7) into .build/screenshots.
.PHONY: archive screenshots
ARCHIVE := $(CURDIR)/.build/Waypoints.xcarchive
archive: generate
	@echo "==> xcodebuild archive (Release)"
	@cd ios && xcodebuild -project Waypoints.xcodeproj -scheme Waypoints -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath '$(DERIVED_DATA)' \
		-archivePath '$(ARCHIVE)' -skipPackagePluginValidation -allowProvisioningUpdates \
		$(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM)) -quiet archive
	@echo "==> $(ARCHIVE)"

screenshots:
	tools/screenshots/shots.sh

clean:
	rm -rf '$(DERIVED_DATA)' ios/Waypoints.xcodeproj
