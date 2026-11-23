#!/usr/bin/env perl
use strict;
use warnings;

my ($crypto, $ssl, $report) = @ARGV;
open my $file, '<', $report or die "Cannot read $report: $!\n";
my $text = do { local $/; <$file> };
die "Expected x64 COFF image\n" unless $text =~ /^Format: COFF-x86-64\r?$/m;
my @names = $text =~ /^  Name: ([^\r\n]+)\r?$/mg;
die "Missing native PE import table\n" unless @names;

my %private = map { lc($_) => 1 } ($crypto, $ssl, qw(libuv-1.dll libllhttp-9.4.dll libsqlite3-0.dll));
my %system = map { $_ => 1 } qw(
    kernel32.dll ucrtbase.dll advapi32.dll user32.dll psapi.dll iphlpapi.dll
    userenv.dll ws2_32.dll dbghelp.dll ole32.dll shell32.dll gdi32.dll crypt32.dll
);
# libuv imports the Windows WaitOnAddress synchronization API contract.
$system{'api-ms-win-core-synch-l1-2-0.dll'} = 1;
# MSYS2 OpenSSL 4 libcrypto imports Windows CNG.
$system{'bcrypt.dll'} = 1;
for my $name (@names) {
    $name = lc $name;
    die "Unexpected native dependency: $name\n"
        unless $private{$name} || $system{$name} || $name =~ /^api-ms-win-crt-[a-z0-9-]+\.dll$/;
}
