#!/usr/bin/env perl
use strict;
use warnings;
use Digest::SHA;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);

my ($root, $manifest) = @ARGV;
die "usage: prepare_windows_native.pl SOURCE_ROOT MANIFEST\n" unless @ARGV == 2;
sub digest {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "$path: $!\n";
    return Digest::SHA->new(256)->addfile($file)->hexdigest;
}
sub read_file {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "$path: $!\n";
    local $/;
    return <$file>;
}
sub write_file {
    my ($path, $text) = @_;
    open my $file, '>:raw', $path or die "$path: $!\n";
    print {$file} $text or die "$path: $!\n";
    close $file or die "$path: $!\n";
}
sub change {
    my ($path, $before, $after) = @_;
    my $text = read_file($path);
    my $count = () = $text =~ /\Q$before\E/g;
    die "$path: expected one pinned source anchor, found $count\n" unless $count == 1;
    $text =~ s/\Q$before\E/$after/;
    write_file($path, $text);
}
make_path($root);
my $recipe = digest($0);
for my $line (split /\n/, read_file($manifest)) {
    next if $line eq '';
    my ($name, $directory, $archive, $sha, $url) = split /\t/, $line;
    die "malformed dependency manifest\n" unless defined($url) && $sha =~ /^[a-f0-9]{64}$/;
    if (!-f $archive) {
        my $download = tempdir('.native-download-XXXXXX', DIR => '.', CLEANUP => 1);
        system('curl', '--fail', '--location', '--output', "$download/source.tar.gz", $url) == 0
            or die "download failed: $name\n";
        die "checksum mismatch: $name\n" unless digest("$download/source.tar.gz") eq $sha;
        rename "$download/source.tar.gz", $archive or die "save $archive: $!\n";
    }
    die "checksum mismatch: $name\n" unless digest($archive) eq $sha;
    my $destination = "$root/$directory";
    my $stamp = "$destination/.titan-windows-source";
    my $identity = "$sha\n$recipe\n";
    if (-e $destination) {
        die "refusing to replace unstamped source: $destination\n" unless -f $stamp;
        next if read_file($stamp) eq $identity;
    }
    my $stage = tempdir('.native-source-XXXXXX', DIR => $root, CLEANUP => 1);
    system('tar', '-xzf', $archive, '-C', $stage) == 0 or die "extract $archive failed\n";
    my $source = "$stage/$directory";
    die "missing expected source directory: $directory\n" unless -d $source;
    if ($name eq 'llhttp') {
        change("$source/include/llhttp.h", <<'BEFORE', <<'AFTER');
#elif defined(_WIN32)
#define LLHTTP_EXPORT __declspec(dllexport)
BEFORE
#elif defined(_WIN32) && defined(TITAN_LLHTTP_BUILD_DLL)
#define LLHTTP_EXPORT __declspec(dllexport)
#elif defined(_WIN32)
#define LLHTTP_EXPORT __declspec(dllimport)
AFTER
    }
    elsif ($name eq 'sqlite3') {
        # sqlite3.c embeds the same public header; configure both exact copies.
        for my $file (qw(sqlite3.h sqlite3.c)) {
            change("$source/$file", <<'BEFORE', <<'AFTER');
#ifndef SQLITE_API
# define SQLITE_API
#endif
BEFORE
#ifndef SQLITE_API
# if defined(_WIN32) && defined(TITAN_SQLITE_BUILD_DLL)
#  define SQLITE_API __declspec(dllexport)
# elif defined(_WIN32)
#  define SQLITE_API __declspec(dllimport)
# else
#  define SQLITE_API
# endif
#endif
AFTER
        }
    }
    write_file("$source/.titan-windows-source", $identity);
    remove_tree($destination) if -e $destination;  # validated stamp above
    rename $source, $destination or die "publish $destination: $!\n";
}
