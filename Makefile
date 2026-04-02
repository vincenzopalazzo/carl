ZIG ?= zig

default: build

build:
	$(ZIG) build

check:
	$(ZIG) build test

fmt:
	$(ZIG) fmt src/

clean:
	rm -rf zig-out .zig-cache zig-cache
