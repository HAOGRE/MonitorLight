.PHONY: test build install uninstall dmg screenshots clean

test:
	bash scripts/test.sh

build:
	bash scripts/build.sh

install: build
	bash scripts/install.sh

uninstall:
	bash scripts/uninstall.sh

dmg: build
	bash scripts/make-dmg.sh

screenshots:
	bash scripts/screenshots.sh

clean:
	rm -rf .build.noindex/MonitorLight.app build/model-tests build/protocol-tests build/render-preview
