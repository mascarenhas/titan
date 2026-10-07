#!/usr/bin/env perl
use strict;
use warnings;
my $allow_extra = @ARGV && $ARGV[0] eq '--allow-extra-exports';
shift @ARGV if $allow_extra;
my ($image, @expected) = @ARGV;
die "usage: check_windows_compiler_pe.pl [--allow-extra-exports] IMAGE [EXPORT ...]\n" unless defined $image;
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
    $lua++ if $name eq 'lua55.dll';
    die "unexpected dependency $name in $image\n" unless
        $name eq 'lua55.dll' || $name eq 'kernel32.dll' ||
        $name eq 'ucrtbase.dll' || $name =~ /^api-ms-win-crt-[a-z0-9-]+[.]dll$/;
}
die "missing controlled Lua import\n" unless $lua == 1;
if ($allow_extra) {
    # Upstream LuaRocks builds may expose ordinary library helper functions.
    my %exports = map { $_ => 1 } @exports;
    die "missing public module opener $_\n" for grep { !$exports{$_} } @expected;
} else {
    die "unexpected export inventory\n" unless join("\n", sort @exports) eq join("\n", sort @expected);
}
die "unexpected export forwarding\n" if $text =~ /ForwardedTo:/;
print "$image: controlled Lua + Windows/UCRT imports; public exports verified\n";
