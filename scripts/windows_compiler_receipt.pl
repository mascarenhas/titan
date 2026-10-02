#!/usr/bin/env perl
use strict;
use warnings;
use Digest::SHA;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use FindBin;

# This is a source-build receipt, not a LuaRocks manifest or a signed build
# attestation. Versions describe the exact tagged archives in dependencies.tsv.
my ($mode, $prefix, $build) = @ARGV;
die "usage: windows_compiler_receipt.pl write PREFIX BUILD | check PREFIX\n"
    unless defined($mode) && defined($prefix)
        && (($mode eq 'write' && @ARGV == 3) || ($mode eq 'check' && @ARGV == 2));
my $repo = "$FindBin::Bin/..";
my $relative = 'share/titan/0.6/compiler-dependencies.tsv';
my $notice_root = 'share/titan/0.6/licenses';
my @dependencies = (
    ['lpeglabel', 'lpeglabel', '1.6.2-1', 'lpeglabel-1.6.2-1', 'LICENSE', [
        ['lib/lua/5.5/lpeglabel.dll', 'object', 'lpeglabel.dll'],
        ['share/lua/5.5/relabel.lua', 'source', 'relabel.lua'],
    ]],
    ['lfs', 'luafilesystem', '1.9.0', 'luafilesystem-1_9_0', 'LICENSE', [
        ['lib/lua/5.5/lfs.dll', 'object', 'lfs.dll'],
    ]],
    ['inspect', 'inspect', '3.1.3', 'inspect.lua-3.1.3', 'MIT-LICENSE.txt', [
        ['share/lua/5.5/inspect.lua', 'source', 'inspect.lua'],
    ]],
    ['argparse', 'argparse', '0.7.2', 'argparse-0.7.2', 'LICENSE', [
        ['share/lua/5.5/argparse.lua', 'source', 'src/argparse.lua'],
    ]],
);

sub read_file {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "$path: $!\n";
    local $/;
    return <$file>;
}
sub digest {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "$path: $!\n";
    return Digest::SHA->new(256)->addfile($file)->hexdigest;
}
sub same_bytes {
    my ($installed, $input) = @_;
    die "installed dependency differs from build input: $installed\n"
        unless digest($installed) eq digest($input);
}

my %manifest;
for my $line (split /\n/, read_file("$repo/vendor/windows-compiler/dependencies.tsv")) {
    next if $line eq '';
    my @fields = split /\t/, $line, -1;
    die "malformed compiler dependency manifest\n" unless @fields == 5
        && $fields[2] =~ /^[A-Za-z0-9_.-]+$/ && $fields[3] =~ /^[a-f0-9]{64}$/;
    my ($id, $directory, $archive, $sha) = @fields;
    die "duplicate compiler dependency: $id\n" if exists $manifest{$id};
    $manifest{$id} = [$directory, $archive, $sha];
}
die "unexpected compiler dependency set\n" unless keys(%manifest) == @dependencies;

my $receipt = join("\t", qw(source_name source_version source_sha256
    artifact_path artifact_sha256 notice_path notice_sha256)) . "\n";
for my $dependency (@dependencies) {
    my ($id, $name, $version, $directory, $license, $artifacts) = @$dependency;
    my $input = $manifest{$id} or die "missing compiler dependency: $id\n";
    my ($pinned_directory, $archive, $source_sha) = @$input;
    die "compiler dependency version/directory mismatch: $id\n"
        unless $directory eq $pinned_directory;
    my $source = defined($build) ? "$build/compiler-src/$directory" : undef;
    my $notice = "$notice_root/$name.txt";
    if ($mode eq 'write') {
        # prepare_windows_native.pl keeps verified archives in the build caller's
        # working directory and records archive + recipe digests in each tree.
        die "compiler source archive checksum mismatch: $archive\n"
            unless digest($archive) eq $source_sha;
        my $identity = "$source_sha\n" . digest("$repo/scripts/prepare_windows_native.pl") . "\n";
        die "compiler source stamp mismatch: $directory\n"
            unless read_file("$source/.titan-windows-source") eq $identity;
        same_bytes("$prefix/$notice", "$source/$license");
    }
    my $notice_sha = digest("$prefix/$notice");
    for my $artifact (@$artifacts) {
        my ($path, $kind, $filename) = @$artifact;
        if ($mode eq 'write') {
            my $original = $kind eq 'object' ? "$build/compiler-objects/$filename" : "$source/$filename";
            same_bytes("$prefix/$path", $original);
        }
        $receipt .= join("\t", $name, $version, $source_sha, $path,
            digest("$prefix/$path"), $notice, $notice_sha) . "\n";
    }
}

my $destination = "$prefix/$relative";
if ($mode eq 'check') {
    die "compiler dependency receipt mismatch: $destination\n"
        unless read_file($destination) eq $receipt;
    print "Compiler dependency receipt verified: $destination\n";
} else {
    make_path("$prefix/share/titan/0.6");
    my ($file, $temporary) = tempfile('.compiler-dependencies-XXXXXX',
        DIR => "$prefix/share/titan/0.6", UNLINK => 1);
    binmode $file;
    print {$file} $receipt or die "write compiler dependency receipt: $!\n";
    close $file or die "close compiler dependency receipt: $!\n";
    chmod 0644, $temporary or die "chmod compiler dependency receipt: $!\n";
    rename $temporary, $destination or die "publish compiler dependency receipt: $!\n";
    print "Compiler dependency receipt installed: $destination\n";
}
