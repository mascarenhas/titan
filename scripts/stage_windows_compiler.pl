#!/usr/bin/env perl
use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Basename qw(dirname);
my ($rockspec, $destination) = @ARGV;
die "usage: stage_windows_compiler.pl ROCKSPEC DESTINATION\n" unless @ARGV == 2;
open my $input, '<:raw', $rockspec or die "$rockspec: $!\n";
local $/;
my $text = <$input>;
my %seen;
while ($text =~ /^\s*\["((?:titan-compiler|c-parser)[.][A-Za-z0-9_.]+)"\] = "((?:titan-compiler|c-parser)\/[A-Za-z0-9_\/]+[.]lua)",?\s*$/mg) {
    my ($module, $source) = ($1, $2);
    (my $relative = $module) =~ s{[.]}{/}g;
    $relative .= '.lua';
    die "module/source mismatch: $module\n" unless $source eq $relative;
    die "duplicate compiler module: $module\n" if $seen{$module}++;
    my $path = "$destination/$relative";
    make_path(dirname($path));
    copy($source, $path) or die "$source -> $path: $!\n";
}
die "no compiler modules in rockspec\n" unless %seen;
print 'Installed ', scalar(keys %seen), " compiler Lua modules from rockspec\n";
