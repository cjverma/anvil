PREFIX ?= /usr/local/anvil
BUILD_DIR := .build/release

.PHONY: test build bundle install uninstall clean

test:
	swift run anvil-selftest

build:
	swift build -c release

bundle: build
	./scripts/bundle-app.sh

install: bundle
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh

clean:
	swift package clean
	rm -rf Anvil.app
