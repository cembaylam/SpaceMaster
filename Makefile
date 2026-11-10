.PHONY: build app run dev test bench clean icon dist
build:
	swift build
app:
	scripts/bundle-app.sh release
run:
	scripts/bundle-app.sh debug
	@pkill -x SpaceMaster; while pgrep -x SpaceMaster >/dev/null; do sleep 0.1; done
	open -n build/SpaceMaster.app
dev:
	scripts/bundle-app.sh debug
	build/SpaceMaster.app/Contents/MacOS/SpaceMaster
test:
	swift test
bench:
	swift run -c release sm-bench $(DIR)
icon:
	swift scripts/make-icon.swift
dist:
	scripts/package.sh
clean:
	rm -rf .build build dist
