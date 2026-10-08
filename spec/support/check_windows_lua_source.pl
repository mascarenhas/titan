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
                 lua_ident luai_ctype_ luaP_opmodes luaT_typenames_);
my $import_pattern = join '|', map { quotemeta $_ } @imports;

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
        capture($clang, @target, @{$modes[$number]}, @language_flags, @cflags,
            '-Werror', '-c', $fixture, '-o', $object);
        my $symbols = capture($readobj, '--symbols', '--coff-directives', $object);
        die "$label consumer is not x86_64 COFF\n" unless $symbols =~ /Format: COFF-x86-64/;
        for my $name (@imports) {
            die "$label consumer mode $number does not import $name through its IAT\n"
                unless $symbols =~ /Name: __imp_\Q$name\E(?:\r?\n)/;
        }
        die "$label consumer entry point lost its C export name\n"
            unless $symbols =~ /-export:luaopen_titan_annotation_probe(?:\s|$)/;
        die "$label consumer unexpectedly exports Lua-owned symbols\n"
            if $symbols =~ /-export:(?:$import_pattern)(?:\s|$)/;
        my $library_export = $symbols =~ /-export:titan_annotation_library_probe(?:\s|$)/;
        my $library_mode = grep { $_ eq '-DLUA_LIB' } @{$modes[$number]};
        die "$label consumer mode $number has incorrect external library export ownership\n"
            unless !!$library_export == !!$library_mode;
    }
}

my $producer = capture($clang, @target, '-DTITAN_LUA_BUILD_DLL',
    '-E', '-P', $fixture);
for my $name (@imports) {
    die "producer does not export declaration $name\n"
        unless $producer =~ /__attribute__\(\(dllexport\)\)[^;\n]*\b\Q$name\E\b/;
}
# Compile an actual pinned Lua data definition, not a fabricated producer.
capture($clang, @target, '-DTITAN_LUA_BUILD_DLL', '-std=c99', @cflags, '-Werror',
    '-c', "$source/lctype.c", '-o', "$temporary/lctype.o");
my $data = capture($readobj, '--coff-directives', "$temporary/lctype.o");
die "Lua internal data definition does not export DATA\n"
    unless $data =~ /-export:luai_ctype_,data/;

print "Windows Lua headers: four C/C++ consumer modes, auxiliary IAT imports, external library exports, producer declarations, real COFF DATA export passed\n";
print "This checks COFF/header ownership only; it does not build or run the Windows Lua DLL.\n";
