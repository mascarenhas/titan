#!/usr/bin/env perl
use strict;
use warnings;
use Text::ParseWords qw(shellwords);
use File::Temp qw(tempdir);

my ($source, $clang, $readobj) = @ARGV;
die "usage: check_windows_lua_source.pl CONFIGURED_LUA_SOURCE CLANG LLVM_READOBJ\n"
    unless @ARGV == 3;
my $profile = $ENV{TITAN_BUILD_PROFILE} // 'validation';
die "TITAN_BUILD_PROFILE must be production or validation\n"
    unless $profile eq 'production' || $profile eq 'validation';
my @cflags = $profile eq 'validation' ? ('-O0', '-fno-lto') : ('-O2');
for my $name (qw(LUA_CFLAGS TITAN_EXTRA_CFLAGS)) {
    next unless exists $ENV{$name};
    my @words = shellwords($ENV{$name});
    die "Malformed argument string: $name\n" if $ENV{$name} =~ /\S/ && !@words;
    push @cflags, @words;
}
my $temporary = tempdir('titan-lua-coff-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $fixture = 'spec/fixtures/windows/lua_annotations.c';
my @imports = qw(lua_gettop luaL_checkversion_ luaL_openselectedlibs luaopen_base luaO_ceillog2
                 luai_ctype_ luaP_opmodes luaT_typenames_);
my $import_pattern = join '|', map { quotemeta $_ } (@imports, 'lua_ident');
# The controlled DLL is built with -DLUA_BUILD_AS_DLL; consumers add these
# definitions so every public and internal symbol is an explicit import.
my @consumer = ('-DLUA_BUILD_AS_DLL',
    '-DLUAI_FUNC=__declspec(dllimport) extern',
    '-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec',
    '-DLUAI_DDEF=');

sub capture {
    my @command = @_;
    open my $pipe, '-|', @command or die "cannot start $command[0]: $!\n";
    local $/;
    my $output = <$pipe>;
    close $pipe or die "$command[0] failed: $?\n";
    return $output;
}

my @target = ('--target=x86_64-w64-windows-gnu', "-I$source");
my @modes = ([], ['-DLUA_CORE'], ['-DLUA_LIB'], ['-DLUA_CORE', '-DLUA_LIB']);
for my $language (['C', '-std=c99'], ['C++', '-x', 'c++', '-std=c++11']) {
    my ($label, @language_flags) = @$language;
    for my $number (0 .. $#modes) {
        my $object = "$temporary/consumer-$label-$number.o";
        capture($clang, @target, @{$modes[$number]}, @consumer, @language_flags, @cflags,
            '-Werror', '-c', $fixture, '-o', $object);
        my $symbols = capture($readobj, '--symbols', '--coff-directives', $object);
        die "$label consumer is not x86_64 COFF\n" unless $symbols =~ /Format: COFF-x86-64/;
        for my $name (@imports) {
            die "$label consumer mode $number does not import $name through its IAT\n"
                unless $symbols =~ /Name: __imp_\Q$name\E(?:\r?\n)/;
        }
        die "$label consumer must not name lua_ident as an import\n"
            if $symbols =~ /Name: __imp_lua_ident(?:\r?\n)/;
        die "$label consumer does not keep the plain C opener name\n"
            unless $symbols =~ /Name: luaopen_titan_annotation_probe(?:\r?\n)/;
        die "$label consumer mangles the provider opener name\n"
            if $symbols =~ /Name: _Z\w*luaopen_titan_annotation_probe/;
        die "$label consumer annotates its provider opener for export\n"
            if $symbols =~ /-export:luaopen_titan_annotation_probe(?:\s|$)/;
        die "$label consumer unexpectedly exports Lua-owned symbols\n"
            if $symbols =~ /-export:(?:$import_pattern)(?:\s|$)/;
        # Stock LUALIB_API follows LUA_API, so only a core/library source role
        # makes a third-party definition exported.
        my $library_export = $symbols =~ /-export:titan_annotation_library_probe(?:\s|$)/;
        my $library_mode = grep { $_ eq '-DLUA_CORE' || $_ eq '-DLUA_LIB' } @{$modes[$number]};
        die "$label consumer mode $number has incorrect external library export ownership\n"
            unless !!$library_export == !!$library_mode;
    }
}

# The stock policy: LUA_API is the exported mark only for the DLL's own core
# and library sources, and LUALIB_API/LUAMOD_API simply follow LUA_API. A
# consumer therefore names its internal imports instead of relying on them
# being exported implicitly through declarations.
my $marks = "$temporary/marks.c";
open my $mark_file, '>', $marks or die "cannot write $marks: $!\n";
print {$mark_file} <<'MARKS';
#include "lua.h"
#include "llimits.h"
#define TITAN_STRINGIFY_(x) #x
#define TITAN_STRINGIFY(x) TITAN_STRINGIFY_(x)
const char titan_lua_api_mark[] = TITAN_STRINGIFY(LUA_API);
const char titan_lua_lib_api_mark[] = TITAN_STRINGIFY(LUALIB_API);
const char titan_lua_mod_api_mark[] = TITAN_STRINGIFY(LUAMOD_API);
const char titan_luai_func_mark[] = TITAN_STRINGIFY(LUAI_FUNC);
MARKS
close $mark_file;
sub marks {
    my @flags = @_;
    return capture($clang, @target, '-E', '-P', @flags, $marks);
}
my $dll = marks('-DLUA_BUILD_AS_DLL', '-DLUA_CORE');
die "the DLL build does not export LUA_API\n"
    unless $dll =~ /titan_lua_api_mark\[\] = "__declspec\(dllexport\)"/;
my $consumer = marks(@consumer);
die "a consumer does not import LUA_API\n"
    unless $consumer =~ /titan_lua_api_mark\[\] = "__declspec\(dllimport\)"/;
die "a consumer does not follow LUA_API for LUALIB_API\n"
    unless $consumer =~ /titan_lua_lib_api_mark\[\] = "__declspec\(dllimport\)"/;
die "a consumer does not follow LUA_API for LUAMOD_API\n"
    unless $consumer =~ /titan_lua_mod_api_mark\[\] = "__declspec\(dllimport\)"/;
die "a consumer does not import LUAI_FUNC\n"
    unless $consumer =~ /titan_luai_func_mark\[\] = "__declspec\(dllimport\) extern"/;
die "the DLL build must not import LUAI_FUNC\n"
    if $dll =~ /titan_luai_func_mark\[\] = "__declspec\(dllimport\)/;
my $library = marks('-DLUA_BUILD_AS_DLL', '-DLUA_LIB');
die "a library source role does not export its own definitions\n"
    unless $library =~ /titan_lua_lib_api_mark\[\] = "__declspec\(dllexport\)"/;

# Internal functions and data stay plain definitions; the DLL link's
# --export-all-symbols, never a per-source visibility override, exports them.
capture($clang, @target, '-DLUA_BUILD_AS_DLL', '-std=c99', @cflags, '-Werror',
    '-c', "$source/lctype.c", '-o', "$temporary/lctype.o");
my $internal = capture($readobj, '--coff-directives', "$temporary/lctype.o");
die "Lua internal data must stay a plain definition exported by the DLL link\n"
    if $internal =~ /-export:/;

print "Windows Lua headers: four C/C++ consumer modes, explicit IAT imports, external library exports, stock DLL/consumer marks passed\n";
print "This checks COFF/header ownership only; it does not build or run the Windows Lua DLL.\n";
