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
# Only the helper declarations are always imported. The public API is imported
# exactly while LUA_API is dllimport, i.e. for a consumer without LUA_CORE or
# LUA_LIB; stock LUAMOD_API is plain extern "C" in C++, so luaopen_base is a
# direct reference there.
my @internal = qw(luaO_ceillog2 luai_ctype_ luaP_opmodes luaT_typenames_);
my @public = qw(lua_gettop luaL_checkversion_ luaL_openselectedlibs luaopen_base);
my $import_pattern = join '|', map { quotemeta $_ } (@internal, @public, 'lua_ident');
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
        my $core_or_lib = grep { $_ eq '-DLUA_CORE' || $_ eq '-DLUA_LIB' } @{$modes[$number]};
        for my $name (@internal) {
            die "$label consumer mode $number does not import $name through its IAT\n"
                unless $symbols =~ /Name: __imp_\Q$name\E(?:\r?\n)/;
        }
        for my $name (@public) {
            my $imported = !$core_or_lib &&
                !($label eq 'C++' && $name eq 'luaopen_base');
            if ($imported) {
                die "$label consumer mode $number does not import $name through its IAT\n"
                    unless $symbols =~ /Name: __imp_\Q$name\E(?:\r?\n)/;
            } else {
                die "$label consumer mode $number unexpectedly imports $name\n"
                    if $symbols =~ /Name: __imp_\Q$name\E(?:\r?\n)/;
                die "$label consumer mode $number lost its direct reference to $name\n"
                    unless $symbols =~ /Name: \Q$name\E(?:\r?\n)/;
            }
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

# Internal functions and data stay plain definitions; the DLL link's
# --export-all-symbols, never a per-source visibility override, exports them.
capture($clang, @target, '-DLUA_BUILD_AS_DLL', '-std=c99', @cflags, '-Werror',
    '-c', "$source/lctype.c", '-o', "$temporary/lctype.o");
my $internal = capture($readobj, '--coff-directives', "$temporary/lctype.o");
die "Lua internal data must stay a plain definition exported by the DLL link\n"
    if $internal =~ /-export:/;

print "Windows Lua headers: four C/C++ consumer modes, mode-correct IAT and direct references, external library exports, stock public-only annotations passed\n";
print "This checks COFF/header ownership only; it does not build or run the Windows Lua DLL.\n";
