#all: mktemp choma

#mktemp:
#	rm -rf .build-dir
#	mkdir .build-dir

#choma:
#	$(MAKE) -C ChOma TARGET=ios DISABLE_SIGNING=1 DYLIB_LDFLAGS="-install_name @loader_path/libchoma.dylib" $@

all: basebin.tar

subprojects: ChOma XPF MachOMerger opainject libjailbreak systemhook forkfix launchdhook hookd boomerang jbctl idownloadd watchdoghook rootlesshooks dopamine

ChOma: .build .include
	@$(MAKE) -C ChOma TARGET=ios DISABLE_SIGNING=1 DISABLE_TESTS=1 DYLIB_LDFLAGS="-install_name @loader_path/libchoma.dylib"
	@ldid -Cadhoc -s ChOma/output/ios/lib/libchoma.dylib
	@cp ChOma/output/ios/lib/libchoma.dylib .build
	@cp -r ChOma/output/ios/include/choma .include

XPF: .build .include ChOma
	@$(MAKE) -C XPF output/ios/libxpf.dylib CHOMA_PATH=../ChOma CHOMA_DYLIB_PATH="../.build"
	@ldid -Cadhoc -s XPF/output/ios/libxpf.dylib
	@cp XPF/output/ios/libxpf.dylib .build/libxpf.dylib
	@mkdir -p .include/xpf
	@cp XPF/src/xpf.h .include/xpf

MachOMerger: .build .include
	@$(MAKE) -C MachOMerger
	@cp MachOMerger/MachOMerger .build

opainject: .build .include
	@patch -p0 -N opainject/arm64.h < arm64_h_stdint.patch || true
	@patch -p0 -N opainject/Makefile < opainject_makefile.patch || true
	$(MAKE) -C opainject FINALPACKAGE=1
	@ldid -Cadhoc -s opainject/.theos/obj/opainject
	@cp opainject/.theos/obj/opainject .build

libjailbreak: .build .include ChOma
	$(MAKE) -C libjailbreak
	@cp libjailbreak/libjailbreak.dylib .build
	@mkdir -p .include/libjailbreak
	@cp libjailbreak/src/*.h .include/libjailbreak

systemhook: .build .include libjailbreak
	$(MAKE) -C systemhook
	@cp systemhook/systemhook.dylib .build

forkfix: .build .include libjailbreak systemhook
	$(MAKE) -C forkfix
	@cp forkfix/forkfix.dylib .build

launchdhook: .build .include libjailbreak
	$(MAKE) -C launchdhook
	@cp launchdhook/launchdhook.dylib .build

hookd: .build .include libjailbreak
	$(MAKE) -C hookd
	@cp hookd/hookd .build

boomerang: .build .include libjailbreak
	$(MAKE) -C boomerang
	@cp boomerang/boomerang .build

jbctl: .build .include libjailbreak
	$(MAKE) -C jbctl
	@cp jbctl/jbctl .build

idownloadd: .build .include libjailbreak
	$(MAKE) -C idownloadd
	@cp idownloadd/idownloadd .build

watchdoghook: .build .include libjailbreak
	$(MAKE) -C watchdoghook
	@cp watchdoghook/watchdoghook.dylib .build

rootlesshooks: .build .include libjailbreak
	$(MAKE) -C rootlesshooks
	@cp rootlesshooks/.theos/obj/rootlesshooks.dylib .build

dopamine: .build .include libjailbreak XPF ChOma
	$(MAKE) -C dopamine
	@cp dopamine/dopamine .build

.build:
	rm -rf .build
	mkdir -p .build
	cp -r _external/basebin/* .build
	cp _external/basebin/.version .build

.include:
	rm -rf .include
	mkdir -p .include
	cp -r _external/include/* .include
# DO NOT remove xpc headers - iOS 16.2 SDK xpc.modulemap exists but headers are in private location

basebin.tc: subprojects
	@if [ -f ./prebuilt/trustcache ]; then \
		./prebuilt/trustcache create .build/basebin.tc .build; \
	elif command -v trustcache >/dev/null 2>&1; then \
		trustcache create .build/basebin.tc .build; \
	else \
		echo "ERROR: trustcache not found. Either place it in ./prebuilt/ or install it to PATH"; \
		exit 1; \
	fi
	cp .build/basebin.tc basebin.tc

# dyldhook dylibs do not need to be added to the basebin trustcache
dyldhook: basebin.tc
	$(MAKE) -C dyldhook
	@cp dyldhook/*.dylib .build

basebin.tar: basebin.tc dyldhook
	@find ./.build -name ".DS_Store" -delete
	@DYLD_FALLBACK_LIBRARY_PATH="." ./tar --transform "s/^.build/basebin/" -cvf "basebin.tar" ".build" --owner=0 --group=0

clean:
	@$(MAKE) -C ChOma $@
	@$(MAKE) -C XPF $@
	@$(MAKE) -C MachOMerger $@
	@$(MAKE) -C opainject $@
	@$(MAKE) -C libjailbreak $@
	@$(MAKE) -C systemhook $@
	@$(MAKE) -C forkfix $@
	@$(MAKE) -C launchdhook $@
	@$(MAKE) -C boomerang $@
	@$(MAKE) -C jbctl $@
	@$(MAKE) -C idownloadd $@
	@$(MAKE) -C watchdoghook $@
	@$(MAKE) -C rootlesshooks $@
	@$(MAKE) -C dyldhook $@
	@$(MAKE) -C dopamine $@
	@$(MAKE) -C hookd $@
	@rm -rf .build
	@rm -rf .include
	@rm -rf basebin.tar
	@rm -rf basebin.tc

.PHONY: clean .build .include ChOma XPF MachOMerger opainject libjailbreak systemhook forkfix launchdhook hookd boomerang jbctl idownloadd watchdoghook rootlesshooks basebin.tc dyldhook basebin.tar