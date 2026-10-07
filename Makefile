.PHONY: build install uninstall setup verify

build:
	./scripts/build.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

setup: build
	open .build/AppleTranslationSetup.app

verify:
	python3 verify.py
