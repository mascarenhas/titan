#!/usr/bin/env perl
use strict;
use warnings;
my ($image, @expected) = @ARGV;
die "usage: check_windows_compiler_pe.pl IMAGE [EXPORT ...]\n" unless defined $image;
open my $pipe, '-|', 'llvm-readobj', '--coff-imports', '--coff-exports', $image or die $!;
local $/;
my $text = <$pipe>;
close $pipe or die "cannot inspect $image\n";
die "expected x64 COFF image: $image\n" unless $text =~ /^Format: COFF-x86-64\r?$/m;
my @exports;
my $lua = 0;
while ($text =~ /^(Import|Export) \{\r?\n(.*?)^\}/msg) {
    my ($kind, $block) = ($1, $2);
    my ($name) = $block =~ /^  Name: ([^\r\n]+)\r?$/m;
    die "unnamed PE entry\n" unless defined $name;
    if ($kind eq 'Export') { push @exports, $name; next; }
    $name = lc $name;
    $lua++ if $name eq 'lua-5.5.1.dll';
    die "unexpected dependency $name in $image\n" unless
        $name eq 'lua-5.5.1.dll' || $name eq 'kernel32.dll' ||
        $name eq 'ucrtbase.dll' || $name =~ /^api-ms-win-crt-[a-z0-9-]+[.]dll$/;
}
die "missing controlled Lua import\n" unless $lua == 1;
die "unexpected export inventory\n" unless join("\n", sort @exports) eq join("\n", sort @expected);
die "unexpected export forwarding\n" if $text =~ /ForwardedTo:/;
print "$image: controlled Lua + Windows/UCRT imports; exact exports verified\n";
