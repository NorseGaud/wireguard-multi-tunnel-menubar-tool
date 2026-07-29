SHELL=/bin/bash

tmp=${TMPDIR:/=}
brew_bin?=$(shell brew --prefix || echo /usr/local)/bin
brew_prefix?=$(shell brew --prefix 2>/dev/null || echo /usr/local)
wireguard_config_dir=${brew_prefix}/etc/wireguard
convert=${brew_bin}/convert
swiftlint=${brew_bin}/swiftlint
swiftformat=${brew_bin}/swiftformat
tailor=${brew_bin}/tailor

# xcpretty: PATH if available, otherwise user gem bin (works before first install)
xcpretty_cmd := $(shell command -v xcpretty 2>/dev/null || ruby -rrubygems -e 'print File.join(Gem.user_dir, "bin/xcpretty")' 2>/dev/null)
ifdef CI
  xcpretty_install = gem install xcpretty --no-document
else
  xcpretty_install = gem install --user-install xcpretty --no-document
endif

git_sha=$(shell git rev-parse --short HEAD)

swift_sources=$(shell find * -name "*.swift"|grep -vE 'SKQueue|INIParse|\.worktrees/')
other_sources=$(shell find * -name "*.plist"|grep -vE '\.worktrees/') WireGuardMultiTunnel.xcodeproj/project.pbxproj
sources=${swift_sources} ${other_sources} VERSION

version_file=VERSION
version_from_file=$(shell test -s ${version_file} && tr -d ' \t\r\n' < ${version_file})
version?=$(if $(version_from_file),$(version_from_file),$(shell git describe --tags --always --abbrev=0))
next_version:=$(shell printf '%s\n' '$(version)' | awk -F. '{printf "%d.%d\n", $$1, $$2+1}')
new_version?=${next_version}
revisions=$(shell git rev-list --all --count HEAD)
helper_revisions=$(shell git rev-list --all  --count WireGuardMultiTunnelHelper/*.swift)
app_info_plist=WireGuardMultiTunnel/Info.plist
helper_info_plist=WireGuardMultiTunnelHelper/Info.plist
info_plists=${app_info_plist} ${helper_info_plist}
build_number_override=$(filter command environment,$(origin build_number))

# Developer ID release signing (non-CI). CI has no certificates.
CODESIGN_IDENTITY?=Developer ID Application: ONLYHUMN LLC (4JD8RUCQ2W)
DEVELOPMENT_TEAM?=4JD8RUCQ2W
NOTARY_PROFILE?=wireguard-multitunnel
helper_launch_services=Contents/Library/LaunchServices/WireGuardMultiTunnelHelper

# Tests use project signing (Apple Development). Archive gets Developer ID overrides.
ifdef CI
  xcodebuild_flags=CODE_SIGNING_ALLOWED=NO
  xcodebuild_archive_flags=$(xcodebuild_flags)
else
  xcodebuild_flags=
  xcodebuild_archive_flags=CODE_SIGN_IDENTITY="$(CODESIGN_IDENTITY)" DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM)
endif

# Shared shell fragment: sets $$build and $$dmg for the versioned disk image name
define resolve_dmg
build=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' '${app_info_plist}'); \
	test -n "$$build"; \
	dmg="WireGuardMultiTunnel-${version}-$$build.dmg"
endef

# without argument make runs unit tests, builds a distributable image, and installs the app in /Applications
.PHONY: all test test-all
all: test-unit dist install

## Testing & Code quality

# run unit tests only (no sudo)
test: test-unit
test-unit: .test-unit
test-all: .test-unit .test-integration
.test-unit: ${sources} .check | icons ensure-xcpretty
	set -o pipefail; xcodebuild -scheme WireGuardMultiTunnel test $(xcodebuild_flags) | $(xcpretty_cmd)
	@touch $@

# verify code quality
check: .check
.check: ${swift_sources} .fix .check.tailor | ${swiftlint}
	${swiftlint} --strict
	@touch $@

# only run tailor on changed files as it is slow
.check.tailor: ${swift_sources} | .fix ${tailor}
	${tailor} $?
	@touch $@

# automatically fix all trivial code quality issues
fix: .fix
.fix: ${swift_sources} | ${swiftformat}
	${swiftformat} --swiftversion 5 $?
	@touch $@

# setup requirements and run integration tests (prompts for sudo once during prep-integration)
test-integration: .test-integration
.test-integration: ${sources} prep-integration | icons ensure-xcpretty
	# application running in Xcode will hang the test
	-osascript -e 'tell application "Xcode" to set actionResult to stop workspace document 1'
	@set -o pipefail; \
	rc=0; \
	INTEGRATION_BREW_PREFIX=${brew_prefix} xcodebuild -scheme IntegrationTests test $(xcodebuild_flags) | $(xcpretty_cmd) || rc=$$?; \
	$(MAKE) cleanup-integration; \
	if [ $$rc -eq 0 ]; then touch $@; fi; \
	exit $$rc

# install test configs under ${brew_prefix}/etc/wireguard (single sudo prompt)
.PHONY: prep-integration cleanup-integration
prep-integration:
	sudo bash -c '\
		mkdir -p "${wireguard_config_dir}" && \
		chmod 0755 "${wireguard_config_dir}" && \
		cp "$(CURDIR)/IntegrationTests/test-localhost.conf" "${wireguard_config_dir}/" && \
		cp "$(CURDIR)/IntegrationTests/test-invalid.conf" "${wireguard_config_dir}/" && \
		cp "$(CURDIR)/IntegrationTests/test-usr-local.conf" "${wireguard_config_dir}/"'

# remove integration test configs from Homebrew wireguard directory
cleanup-integration:
	sudo rm -f \
		"${wireguard_config_dir}/test-localhost.conf" \
		"${wireguard_config_dir}/test-invalid.conf" \
		"${wireguard_config_dir}/test-usr-local.conf"

## Building and distribution

# Apply CFBundleShortVersionString from VERSION (or overridden `version=`) to both targets
.PHONY: sync-version
sync-version:
	@test -n '${version}' || (echo 'version is empty; set ${version_file} or pass version='; exit 1)
	@for plist in WireGuardMultiTunnel/Info.plist WireGuardMultiTunnelHelper/Info.plist; do \
		current=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$$plist"); \
		if [ "$$current" != '${version}' ]; then \
			/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${version}" "$$plist"; \
		fi; \
	done

# Increment CFBundleVersion in app and helper plists (kept in sync for SMJobBless)
.PHONY: bump-build-number
bump-build-number: sync-version
ifdef CI
	@echo 'CI: skipping build number bump'
else ifneq ($(build_number_override),)
	@test -n '${build_number}' || (echo 'build_number override is empty'; exit 1)
	@for plist in ${info_plists}; do \
		/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${build_number}" "$$plist"; \
	done
	@echo "Build number => ${build_number}"
else
	@current=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' '${app_info_plist}'); \
	case "$$current" in ''|*[!0-9]*) \
		echo "CFBundleVersion must be a positive integer in ${app_info_plist}; got: $$current"; exit 1;; \
	esac; \
	next=$$((10#$$current + 1)); \
	for plist in ${info_plists}; do \
		/usr/libexec/PlistBuddy -c "Set CFBundleVersion $$next" "$$plist"; \
	done; \
	echo "Build number => $$next"
endif

# Location where xcodebuild puts .app when archiving
archive=${tmp}/WireGuardMultiTunnel.xcarchive
build_dest=${archive}/Products/Applications
dist=${tmp}/WireGuardMultiTunnel
dmg_volume=WireGuardMultiTunnel
install_stamp=${tmp}/.wireguard-multitunnel-installed
dmg_stamp=${tmp}/.wireguard-multitunnel-dmg
notarize_stamp=${tmp}/.wireguard-multitunnel-notarized

# Create just the .app in the current working directory
app: WireGuardMultiTunnel.app
WireGuardMultiTunnel.app: ${build_dest}/WireGuardMultiTunnel.app
	rm -rf "$@" && cp -r "${<}" "$@"

# Requirement strings must stay in sync with Info.plist SM* keys and Shared/SecurityValidation.swift
app_codesign_requirement=anchor apple generic and identifier "WireGuardMultiTunnel" and certificate leaf[subject.OU] = "4JD8RUCQ2W"
helper_codesign_requirement=anchor apple generic and identifier "WireGuardMultiTunnelHelper" and certificate leaf[subject.OU] = "4JD8RUCQ2W"

# Deep-sign helper then app (SMJobBless order) with hardened runtime + timestamp
.PHONY: sign
sign: ${build_dest}/WireGuardMultiTunnel.app
ifdef CI
	@echo 'CI: skipping codesign'
else
	@set -euo pipefail; \
	app='${build_dest}/WireGuardMultiTunnel.app'; \
	helper="$$app/${helper_launch_services}"; \
	test -f "$$helper"; \
	codesign --force --options runtime --timestamp --sign '${CODESIGN_IDENTITY}' "$$helper"; \
	codesign --force --options runtime --timestamp --sign '${CODESIGN_IDENTITY}' "$$app"; \
	codesign --verify --deep --strict --verbose=2 "$$app"; \
	codesign -v -R '=${helper_codesign_requirement}' "$$helper"; \
	codesign -v -R '=${app_codesign_requirement}' "$$app"
endif

# Create distributable .dmg in current working directory (version + CFBundleVersion)
.PHONY: dist create-dmg notarize
dist: ${dmg_stamp}
ifndef CI
dist: ${notarize_stamp}
endif

${dmg_stamp}: ${dist}/WireGuardMultiTunnel.app
	@set -euo pipefail; \
	${resolve_dmg}; \
	rm -f WireGuardMultiTunnel-${version}-*.dmg '${notarize_stamp}'; \
	hdiutil create -fs HFS+ "$$dmg" -srcfolder '${dist}' -ov; \
	touch '$@'

create-dmg: ${dmg_stamp}

${notarize_stamp}: ${dmg_stamp}
ifdef CI
	@echo 'CI: skipping notarize'; touch '$@'
else
	@set -euo pipefail; \
	${resolve_dmg}; \
	test -f "$$dmg"; \
	xcrun notarytool submit "$$dmg" --keychain-profile '${NOTARY_PROFILE}' --wait; \
	xcrun stapler staple "$$dmg"; \
	xcrun stapler validate "$$dmg"; \
	touch '$@'
endif

notarize: ${notarize_stamp}

# Zipped distributable with current git commit sha
zip: WireGuardMultiTunnel-${git_sha}.zip
WireGuardMultiTunnel-${git_sha}.zip: ${tmp}/WireGuardMultiTunnel-${git_sha}.app
	cd ${<D}; zip -r ${PWD}/$@ ${<F}

${tmp}/WireGuardMultiTunnel-${git_sha}.app: ${build_dest}/WireGuardMultiTunnel.app
	rm -rf "$@" && cp -r "${<}" "$@"

# Generate contents for distributable .dmg (signed app when not CI)
${dist}/WireGuardMultiTunnel.app: ${build_dest}/WireGuardMultiTunnel.app Misc/Uninstall.sh Misc/Uninstall.applescript
ifndef CI
${dist}/WireGuardMultiTunnel.app: sign
endif
	@set -euo pipefail; \
	rm -rf "${@D}/"; mkdir -p "${@D}/"; \
	ln -sf /Applications "${@D}/Applications"; \
	osacompile -o "${@D}/Uninstall.app" Misc/Uninstall.applescript; \
	cp Misc/Uninstall.sh "${@D}/Uninstall.app/Contents/Resources/Uninstall.sh"; \
	/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string WireGuardMultiTunnelUninstall' "${@D}/Uninstall.app/Contents/Info.plist"; \
	rm -rf "$@" && cp -r "${build_dest}/WireGuardMultiTunnel.app" "$@"
ifndef CI
	@set -euo pipefail; \
	codesign --force --options runtime --timestamp --sign '${CODESIGN_IDENTITY}' "${dist}/Uninstall.app"; \
	codesign --verify --deep --strict --verbose=2 "${dist}/Uninstall.app"
endif

# Generate archive build (this excludes debug symbols (dSYM) which are in a release build)
${build_dest}/WireGuardMultiTunnel.app: bump-build-number ${sources} | icons ensure-xcpretty
	xcodebuild -scheme WireGuardMultiTunnel -archivePath "${archive}" archive $(xcodebuild_archive_flags) | $(xcpretty_cmd)

# install and run the App in /Applications (via mounted .dmg; ditto avoids symlink/xattr cp failures)
.PHONY: install
install: $(install_stamp)
ifdef CI
$(install_stamp): ${dmg_stamp}
else
$(install_stamp): ${notarize_stamp}
endif
	@set -euo pipefail; \
	${resolve_dmg}; \
	volume="/Volumes/${dmg_volume}"; \
	test -f "$$dmg"; \
	osascript -e 'tell application "WireGuardMultiTunnel" to quit' 2>/dev/null || true; \
	hdiutil detach -quiet "$$volume" 2>/dev/null || true; \
	hdiutil attach -quiet -nobrowse "$$dmg"; \
	rm -rf /Applications/WireGuardMultiTunnel.app; \
	ditto "$$volume/WireGuardMultiTunnel.app" /Applications/WireGuardMultiTunnel.app; \
	hdiutil detach -quiet "$$volume"; \
	touch "$(install_stamp)"; \
	open /Applications/WireGuardMultiTunnel.app

uninstall:
	Misc/Uninstall.sh

screenshot: Misc/demo.png
Misc/demo.png: ${all_sources} WireGuardMultiTunnel.app
	Misc/screenshot.sh $@

bump:
	@if ! git diff-index --quiet HEAD;then echo "Uncommited changes!"; exit 1; fi
	@if git tag | grep -w ${new_version};then echo "Version exists!"; exit 1; fi
	@echo '${new_version}' > ${version_file}
	/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${new_version}" WireGuardMultiTunnel/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${revisions}" WireGuardMultiTunnel/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${new_version}" WireGuardMultiTunnelHelper/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${helper_revisions}" WireGuardMultiTunnelHelper/Info.plist
	git add ${version_file} */Info.plist
	git commit --amend --no-edit
	git tag ${new_version}

prep-release: test-all dist install
release: prep-release
	git push
	git push --tags
	open .
	open https://github.com/NorseGaud/macos-menubar-wireguard/releases/edit/${version}

## Icon/image generation

assets=WireGuardMultiTunnel/Assets.xcassets
.PHONY: icons appicon imagesets
icons: appicon imagesets

# The icon used by the application
appicon: \
	${assets}/AppIcon.appiconset/16.png \
	${assets}/AppIcon.appiconset/32.png \
	${assets}/AppIcon.appiconset/64.png \
	${assets}/AppIcon.appiconset/128.png \
	${assets}/AppIcon.appiconset/256.png \
	${assets}/AppIcon.appiconset/512.png \
	${assets}/AppIcon.appiconset/1024.png

# Provide different sizes of appicon
${assets}/AppIcon.appiconset/%.png: Misc/logo.png
	${convert} $< -strip -scale $*x$* $@

# Icons used for the menubar
imagesets: \
	${assets}/silhouette.imageset/Contents.json \
	${assets}/silhouette.imageset/18.png \
	${assets}/silhouette.imageset/36.png \
	${assets}/silhouette-dim.imageset/Contents.json \
	${assets}/silhouette-dim.imageset/18.png \
	${assets}/silhouette-dim.imageset/36.png \
	${assets}/dragon.imageset/Contents.json \
	${assets}/dragon.imageset/18.png \
	${assets}/dragon.imageset/36.png \
	${assets}/dragon-dim.imageset/Contents.json \
	${assets}/dragon-dim.imageset/18.png \
	${assets}/dragon-dim.imageset/36.png

# Provide 2 required sizes for any imageset variant
${assets}/%.imageset/18.png: Misc/%.png
	${convert} $< -strip -scale 18x18 $@
${assets}/%.imageset/36.png: Misc/%.png
	${convert} $< -strip -scale 36x36 $@
# Provide standard imageset definition
${assets}/%.imageset/Contents.json: Misc/imageset.Contents.json
	mkdir -p ${@D}
	cp $< $@

source=circle

# Create a dimmed version of a image
%-dim.png: %.png | ${convert}
	${convert} $< -strip -channel A -evaluate Multiply 0.50 +channel $@

Misc/logo.png:
	${convert} -background transparent -size 1000x1000 xc: -fill black  \
    	-draw 'translate 500,500 circle 0,0 500,0' $@

Misc/dragon.png:
	${convert} -background transparent -size 1000x1000 xc: -fill transparent -stroke black -strokewidth 50  \
    	-draw 'translate 500,500 circle 0,0 400,0' $@

Misc/silhouette.png:
	${convert} -background transparent -size 1000x1000 xc: -fill black  \
    	-draw 'translate 500,500 circle 0,0 500,0' $@

# # Extract the logo part from the banner, color it black and white
# Misc/logo.png: Misc/${source}.png | ${convert}
# 	${convert} --version | grep 7.0.8-9 || exit 1 	# versions 7.0.8-{15,16} have a bug breaking floodfill
# 	${convert} $< -strip -crop 1251x1251+0+0 -colorspace gray +dither -colors 2 \
# 		-floodfill +600+200 white -floodfill +600+400 white -floodfill +350+900 white \
# 		-floodfill +400+200 black -floodfill +777+117 black\
# 		$@

# # Extract the logo part from the banner, invert to keep only the dragon
# Misc/dragon.png: Misc/${source}.png | ${convert}
# 	${convert} --version | grep 7.0.8-9 || exit 1 	# versions 7.0.8-{15,16} have a bug breaking floodfill
# 	${convert} $< -strip -colorspace gray +dither -colors 2 -crop 1251x1251+0+0\
# 		-floodfill +600+200 black -floodfill +600+400 black -floodfill +350+900 black\
# 		-floodfill +400+200 transparent -floodfill +777+117 transparent \
# 		$@

# # Extract the logo part from the banner, but keep the dragon transparent
# Misc/silhouette.png: Misc/${source}.png | ${convert}
# 	${convert} --version | grep 7.0.8-9 || exit 1 	# versions 7.0.8-{15,16} have a bug breaking floodfill
# 	${convert} $< -strip -colorspace gray +dither -colors 2 -crop 1251x1251+0+0 \
# 		-floodfill +400+200 black -floodfill +777+117 black\
# 		$@

# Convert SVG wireguard banner to png
Misc/%.png: Misc/%.svg | ${convert}
	${convert} -strip -background transparent -density 400 $< $@

# Download the official logo
Misc/wireguard.svg:
	curl -s https://www.wireguard.com/img/wireguard.svg > $@

## Setup and maintenance

${convert} ${swiftlint} ${tailor} ${swiftformat}:
	${brew_bin}/brew bundle install --verbose --no-upgrade

# Used to generate less verbose xcodebuild output
.PHONY: ensure-xcpretty
ensure-xcpretty:
	@test -x '$(xcpretty_cmd)' || $(xcpretty_install)

.PHONY: clean mrproper
# cleanup build artifacts
clean:
	rm -rf \
		.{fix,check,test}* \
		${archive} \
		${dist} \
		WireGuardMultiTunnel.app \
		WireGuardMultiTunnel-*.dmg \
		WireGuardMultiTunnel-*.zip \
		${tmp}/WireGuardMultiTunnel-*.app \
		${install_stamp} \
		${dmg_stamp} \
		${notarize_stamp} \
		DerivedData/

# cleanup most artifacts that could be generated by the Makefile
mrproper_images:
	rm -rf \
		Misc/{logo,dragon,wireguard,silhouette}.png  \
		${tmp}/wireguard.png WireGuardMultiTunnel/Assets.xcassets/*.imageset/ \
		WireGuardMultiTunnel/Assets.xcassets/AppIcon.appiconset/logo-*.png

mrproper: clean mrproper_images
	sudo rm -f \
		${wireguard_config_dir}/test-localhost.conf \
		${wireguard_config_dir}/test-invalid.conf \
		${wireguard_config_dir}/test-usr-local.conf
