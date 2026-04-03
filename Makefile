ZIG ?= zig
PREFIX ?= /usr/local

default: build

build:
	$(ZIG) build

check:
	$(ZIG) build test

fmt:
	$(ZIG) fmt src/

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 zig-out/bin/carl $(DESTDIR)$(PREFIX)/bin/carl

clean:
	rm -rf zig-out .zig-cache zig-cache
