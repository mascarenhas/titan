#!/usr/bin/env perl
use strict;
use warnings;
use Text::ParseWords qw(shellwords);
use File::Temp qw(tempdir);
my ($source, $clang, $readobj) = @ARGV;
die "usage: check_windows_native_source.pl SOURCE_ROOT CLANG LLVM_READOBJ\n" unless @ARGV == 3;
my $profile = $ENV{TITAN_BUILD_PROFILE} // 'validation';
die "TITAN_BUILD_PROFILE must be production or validation\n"
    unless $profile eq 'production' || $profile eq 'validation';
my @cflags = $profile eq 'validation' ? ('-O0', '-fno-lto') : ('-O2');
for my $name (qw(NATIVE_CFLAGS TITAN_EXTRA_CFLAGS)) {
    next unless exists $ENV{$name};
    my @words = shellwords($ENV{$name});
    die "Malformed argument string: $name\n" if $ENV{$name} =~ /\S/ && !@words;
    push @cflags, @words;
}
my $temporary = tempdir('titan-native-coff-XXXXXX', TMPDIR => 1, CLEANUP => 1);
sub capture {
    open my $pipe, '-|', @_ or die "start $_[0]: $!\n";
    local $/;
    my $text = <$pipe>;
    close $pipe or die "$_[0] failed: $?\n";
    return $text;
}
my @target = ('--target=x86_64-w64-windows-gnu',
    "-I$source/llhttp-release-v9.4.3/include", "-I$source/sqlite-autoconf-3530400");
my $fixture = 'spec/fixtures/windows/native_annotations.c';
capture($clang, @target, '-std=c99', @cflags, '-Werror', '-c', $fixture, '-o', "$temporary/consumer.o");
my $object = capture($readobj, '--symbols', '--coff-directives', "$temporary/consumer.o");
die "expected x64 COFF\n" unless $object =~ /Format: COFF-x86-64/;
for my $name (qw(llhttp_init llhttp_get_errno sqlite3_open sqlite3_version)) {
    die "native consumer did not use IAT for $name\n" unless $object =~ /Name: __imp_\Q$name\E\r?\n/;
}
die "consumer exports native dependency symbols\n" if $object =~ /-export:(?:llhttp_|sqlite3_)/;
my $producer = capture($clang, @target, '-DTITAN_LLHTTP_BUILD_DLL',
    '-DTITAN_SQLITE_BUILD_DLL', '-E', '-P', $fixture);
for my $name (qw(llhttp_init llhttp_get_errno sqlite3_open sqlite3_version)) {
    die "producer declaration lacks export: $name\n"
        unless $producer =~ /__attribute__\(\(dllexport\)\)[^;]*\b\Q$name\E\b/;
}
print "Windows native headers: actual llhttp/SQLite COFF consumer IATs and producer declarations passed\n";
print "No native Windows DLL was built or executed by this source check.\n";
