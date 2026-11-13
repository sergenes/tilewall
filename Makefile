PREFIX ?= $(HOME)/.local

.PHONY: build test install

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(PREFIX)/bin
	# Copy then rename, so a running daemon keeps its old binary intact until it is restarted.
	cp .build/release/tilewall $(PREFIX)/bin/tilewall.new
	mv -f $(PREFIX)/bin/tilewall.new $(PREFIX)/bin/tilewall
