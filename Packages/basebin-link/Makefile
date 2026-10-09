package: $(TARGET)
	@mkdir -p .package/DEBIAN
	@mkdir -p .package/var/69/usr/bin
	@mkdir -p .package/var/69/usr/lib
	@cp control .package/DEBIAN/control
	@ln -s ../../basebin/jbctl .package/var/69/usr/bin/jbctl
	@ln -s ../../basebin/opainject .package/var/69/usr/bin/opainject
	@ln -s ../../basebin/libjailbreak.dylib .package/var/69/usr/lib/libjailbreak.dylib
	@dpkg-deb --root-owner-group -Zzstd -b .package ./basebin-link.deb
	@rm -rf .package

clean:
	@rm -rf basebin-link.deb