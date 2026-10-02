#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use File::Copy qw(copy);

# Only the checksum-verified, dedicated Windows source stage uses these
# transformations. The ordinary Lua tree and POSIX relocation patch are separate.
my ($source) = @ARGV;
die "usage: configure_windows_lua.pl LUA_SOURCE_DIRECTORY\n"
    unless defined($source) && @ARGV == 1;

sub change {
    my ($name, $before, $after) = @_;
    my $path = "$source/$name";
    open my $input, '<:raw', $path or die "$path: $!\n";
    local $/;
    my $text = <$input>;
    close $input or die "$path: $!\n";
    my $count = () = $text =~ /\Q$before\E/g;
    die "$path: expected one pinned source anchor, found $count\n"
        unless $count == 1;
    $text =~ s/\Q$before\E/$after/;
    open my $output, '>:raw', $path or die "$path: $!\n";
    print {$output} $text or die "$path: $!\n";
    close $output or die "$path: $!\n";
}

change('luaconf.h', <<'BEFORE', <<'AFTER');
#define LUA_LDIR	"!\\lua\\"
#define LUA_CDIR	"!\\"
#define LUA_SHRDIR	"!\\..\\share\\lua\\" LUA_VDIR "\\"
BEFORE
/* Keep stock Windows '!' expansion relative to the running EXE directory. */
#define LUA_LDIR	"!\\..\\share\\lua\\" LUA_VDIR "\\"
#define LUA_CDIR	"!\\..\\lib\\lua\\" LUA_VDIR "\\"
#define LUA_TITAN_CDIR	"!\\..\\lib\\titan\\0.6\\"
#define LUA_SHRDIR	LUA_LDIR
AFTER

change('luaconf.h', <<'BEFORE', <<'AFTER');
#define LUA_PATH_DEFAULT  \
		LUA_LDIR "?.lua;"  LUA_LDIR "?\\init.lua;" \
		LUA_CDIR "?.lua;"  LUA_CDIR "?\\init.lua;" \
		LUA_SHRDIR "?.lua;"  LUA_SHRDIR "?\\init.lua;" \
		".\\?.lua;" ".\\?\\init.lua"
BEFORE
#define LUA_PATH_DEFAULT  \
		LUA_LDIR "?.lua;" LUA_LDIR "?\\init.lua;" \
		".\\?.lua;" ".\\?\\init.lua"
AFTER

change('luaconf.h', <<'BEFORE', <<'AFTER');
#define LUA_CPATH_DEFAULT \
		LUA_CDIR "?.dll;" \
		LUA_CDIR "..\\lib\\lua\\"  LUA_VDIR "\\?.dll;" \
		LUA_CDIR "loadall.dll;" ".\\?.dll"
BEFORE
#define LUA_CPATH_DEFAULT \
		LUA_TITAN_CDIR "?.dll;" LUA_CDIR "?.dll;" \
		LUA_CDIR "loadall.dll;" ".\\?.dll"
AFTER

change('luaconf.h', <<'BEFORE', <<'AFTER');
#if defined(LUA_BUILD_AS_DLL)	/* { */

#if defined(LUA_CORE) || defined(LUA_LIB)	/* { */
BEFORE
/* This SDK belongs to one controlled Lua DLL. LUA_CORE and LUA_LIB describe
** source roles, not DLL ownership: consumers may define either of them. */
#if defined(_WIN32) && !defined(LUA_BUILD_AS_DLL)
#define LUA_BUILD_AS_DLL
#endif
#if defined(LUA_BUILD_AS_DLL)	/* { */

#if defined(TITAN_LUA_BUILD_DLL)	/* { */
AFTER

change('luaconf.h', <<'BEFORE', <<'AFTER');
#if defined(__cplusplus)
/* Lua uses the "C name" when calling open functions */
#define LUAMOD_API	extern "C"
#else
#define LUAMOD_API	LUA_API
#endif
BEFORE
/* Module opening definitions export independently of calls into Lua.
** lualib.h uses LUALIB_API for declarations of Lua's built-in openers. */
#if defined(_WIN32)
#if defined(__cplusplus)
#define LUAMOD_API extern "C" __declspec(dllexport)
#else
#define LUAMOD_API __declspec(dllexport)
#endif
#elif defined(__cplusplus)
#define LUAMOD_API extern "C"
#else
#define LUAMOD_API LUA_API
#endif
AFTER

change('llimits.h', <<'BEFORE', <<'AFTER');
#if !defined(LUAI_FUNC)

#if defined(__GNUC__) && ((__GNUC__*100 + __GNUC_MINOR__) >= 302) && \
BEFORE
/* Titan's configured SDK exposes pinned Lua internals, including data.
** Only the Lua DLL build defines TITAN_LUA_BUILD_DLL. */
#if defined(_WIN32)
#define LUAI_FUNC LUA_API extern
#define LUAI_DDEC(dec) LUA_API extern dec
#define LUAI_DDEF LUA_API
#endif

#if !defined(LUAI_FUNC)

#if defined(__GNUC__) && ((__GNUC__*100 + __GNUC_MINOR__) >= 302) && \
AFTER

change('lua.h', 'extern const char lua_ident[];', <<'AFTER');
#if defined(_WIN32)
LUA_API extern const char lua_ident[];
#else
extern const char lua_ident[];
#endif
AFTER
change('lapi.c', 'const char lua_ident[] =', <<'AFTER');
#if defined(_WIN32)
LUA_API
#endif
const char lua_ident[] =
AFTER

for my $library (qw(base coroutine debug io math os string table utf8 package)) {
    my $symbol = $library eq 'base' ? 'luaopen_base' : "luaopen_$library";
    change('lualib.h', "LUAMOD_API int ($symbol)",
        "LUALIB_API int ($symbol)");
}

# Pin numeric/layout-affecting options in the installed SDK, rather than letting
# a producer-only command-line setting silently change the consumer ABI.
change('luaconf.h', "#define LUA_INT_DEFAULT\t\tLUA_INT_LONGLONG", <<'AFTER');
#if defined(_WIN32) && (defined(LUA_32BITS) || defined(LUA_INT_TYPE) || \
    defined(LUA_FLOAT_TYPE) || defined(LUA_INT_DEFAULT) || \
    defined(LUA_FLOAT_DEFAULT))
#error "The controlled Lua DLL requires its installed default numeric configuration"
#endif
#define LUA_INT_DEFAULT		LUA_INT_LONGLONG
AFTER

# The surrounding loader backends remain exactly upstream. Keep the Windows
# policy readable as a separate, installed source file.
{
    my $path = "$source/loadlib.c";
    open my $input, '<:raw', $path or die "$path: $!\n";
    local $/;
    my $text = <$input>;
    close $input or die "$path: $!\n";
    my $count = $text =~ s{\#include <windows[.]h>.*?(?=/\* \}====================================================== \*/)}{#include "titan_windows_loadlib.h"\n\n}s;
    die "$path: expected one Windows loader block\n" unless $count == 1;
    open my $output, '>:raw', $path or die "$path: $!\n";
    print {$output} $text or die "$path: $!\n";
    close $output or die "$path: $!\n";
}
copy("$FindBin::Bin/../vendor/lua/titan_windows_loadlib.h",
    "$source/titan_windows_loadlib.h") or die "copy Windows loader: $!\n";
change('loadlib.c', '  return searchpath(L, name, path, ".", dirsep);', <<'AFTER');
#if defined(LUA_DL_DLL)
  path = titan_win_checkstring(L, -1);
#endif
  return searchpath(L, name, path, ".", dirsep);
AFTER
