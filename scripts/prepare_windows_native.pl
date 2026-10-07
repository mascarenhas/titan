#!/usr/bin/env perl
use strict;
use warnings;
use Digest::SHA;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my ($root, $manifest, $openssl_mode) = @ARGV;
$openssl_mode //= $ENV{OPENSSL_MODE} // 'system';
die "usage: prepare_windows_native.pl SOURCE_ROOT MANIFEST [system|bundled]\n"
    unless (@ARGV == 2 || @ARGV == 3) && $openssl_mode =~ /^(system|bundled)$/;
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
my $libuv_patch = "$Bin/../vendor/libuv/libuv-1.53.0-windows-write-reentry.patch";
my $libbacktrace_patch = "$Bin/../vendor/libbacktrace/libbacktrace-0b9b49c-windows-images.patch";
for my $line (split /\n/, read_file($manifest)) {
    next if $line eq '';
    my ($name, $directory, $archive, $sha, $url) = split /\t/, $line;
    die "malformed dependency manifest\n" unless defined($url) && $sha =~ /^[a-f0-9]{64}$/;
    next if $name eq 'openssl' && $openssl_mode eq 'system';
    my $destination = "$root/$directory";
    my $stamp = "$destination/.titan-windows-source";
    next if -f $stamp;  # completed pinned acquisition and source patches
    die "remove incomplete source directory: $destination\n" if -e $destination;
    if (!-f $archive) {
        my $download = tempdir('.native-download-XXXXXX', DIR => '.', CLEANUP => 1);
        system('curl', '--fail', '--location', '--output', "$download/source.tar.gz", $url) == 0
            or die "download failed: $name\n";
        die "checksum mismatch: $name\n" unless digest("$download/source.tar.gz") eq $sha;
        rename "$download/source.tar.gz", $archive or die "save $archive: $!\n";
    }
    die "checksum mismatch: $name\n" unless digest($archive) eq $sha;
    my $stage = tempdir('.native-source-XXXXXX', DIR => $root, CLEANUP => 1);
    system('tar', '-xzf', $archive, '-C', $stage) == 0 or die "extract $archive failed\n";
    my $source = "$stage/$directory";
    die "missing expected source directory: $directory\n" unless -d $source;
    if ($name eq 'libuv') {
        system('git', '-C', $source, 'apply', '--no-index', '--check', $libuv_patch) == 0
            or die "libuv Windows write patch does not match pinned source\n";
        system('git', '-C', $source, 'apply', '--no-index', $libuv_patch) == 0
            or die "libuv Windows write patch failed\n";
    }
    elsif ($name eq 'libbacktrace') {
        system('git', '-C', $source, 'apply', '--no-index', '--check', $libbacktrace_patch) == 0
            or die "libbacktrace Windows image patch does not match pinned source\n";
        system('git', '-C', $source, 'apply', '--no-index', $libbacktrace_patch) == 0
            or die "libbacktrace Windows image patch failed\n";
    }
    elsif ($name eq 'llhttp') {
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
    write_file("$source/.titan-windows-source", "$sha\n");
    rename $source, $destination or die "publish $destination: $!\n";
}
