# Build the example Titan modules.
#
# titanc must run from the repository ROOT: it resolves titan-runtime/ and the
# Lua source tree relative to the working directory, and the modules refer to
# themselves as `examples.*` (e.g. `import "examples.utils"`). So each target
# does `cd .. && ./titanc examples.<name>` — output lands in ../out/examples/.
#
# Run `make -C .. examples` (or `make all` from this directory) to build them
# all. The SDL examples need SDL2 installed. titanc has no -I/-L flags, so for an
# SDL2 outside the default compiler search paths, point the C compiler at it via
# the environment, e.g.:
#   make sdl_demo CPATH=/path/to/include LIBRARY_PATH=/path/to/lib
# and run with LD_LIBRARY_PATH=/path/to/lib so libSDL2 is found at load time.

TITANC := ./titanc --output out

.PHONY: all artisanal sdl_demo sdl_quit utils clean

all: utils artisanal sdl_quit sdl_demo

# Pure Titan, no dependencies -> utils.so and utils.a
utils:
	cd .. && $(TITANC) examples.utils

# Imports examples.utils -> artisanal.so and artisanal.a
artisanal: utils
	cd .. && $(TITANC) examples.artisanal

# foreign import "SDL2/SDL.h" (needs SDL2 headers) -> sdl_quit.so and
# sdl_quit.a. Links SDL2 so the DSO is self-contained (the driver dlopens it to
# read its interface when another module imports it).
sdl_quit:
	cd .. && $(TITANC) examples.sdl_quit -l SDL2

# Imports examples.sdl_quit and SDL2, has main -> sdl_demo executable.
# Links SDL2 (see the header comment in sdl_demo.titan).
sdl_demo: sdl_quit
	cd .. && $(TITANC) examples.sdl_demo -l SDL2

clean:
	rm -rf ../out/examples
