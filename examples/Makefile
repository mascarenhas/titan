# Build the example Titan modules.
#
# titanc must run from the repository ROOT: it resolves titan-runtime/ and the
# Lua source tree relative to the working directory, and the modules refer to
# themselves as `examples.*` (e.g. `import "examples.utils"`). So each target
# does `cd .. && ./titanc examples.<name>` — output lands back here in examples/.
#
# Run `make -C .. examples` (or `make all` from this directory) to build them
# all. The SDL examples need the SDL2 development headers installed.

TITANC := ./titanc

.PHONY: all artisanal sdl_demo sdl_quit utils clean

all: utils artisanal sdl_quit sdl_demo

# Pure Titan, no dependencies -> utils.so
utils:
	cd .. && $(TITANC) examples.utils

# Imports examples.utils -> artisanal.so
artisanal: utils
	cd .. && $(TITANC) examples.artisanal

# foreign import "SDL2/SDL.h" (needs SDL2 headers) -> sdl_quit.so
sdl_quit:
	cd .. && $(TITANC) examples.sdl_quit

# Imports examples.sdl_quit and SDL2, has main -> sdl_demo executable.
# Links SDL2 (see the header comment in sdl_demo.titan).
sdl_demo: sdl_quit
	cd .. && $(TITANC) examples.sdl_demo -l SDL2

clean:
	rm -f *.c *.o *.so sdl_demo
