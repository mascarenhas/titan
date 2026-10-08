package WindowsLibbacktraceAllocator;
use strict;
use warnings;
use Digest::SHA;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);

my $vendor = dirname(abs_path(__FILE__)) . '/../vendor/libbacktrace';
my $original_sha = 'f007fd4a3cce9db6dd16eebebe744a78a04a4589639e1b2c8f5a431a47d9aece';
my $patched_sha = 'cf7162a6ccb2f50c7b326ec9b7b6ca864976f00b25b3832d12079b5c24765f7a';
my $patch = "$vendor/libbacktrace-0b9b49c-alloc-growth.patch";
my $receipt_name = '.titan-windows-libbacktrace-allocator';

sub ordinary {
    my ($path) = @_;
    die "ordinary libbacktrace file required: $path\n" unless -f $path && !-l $path;
}
sub read_file {
    my ($path) = @_;
    ordinary($path);
    open my $file, '<:raw', $path or die "$path: $!\n";
    local $/;
    return <$file>;
}
sub digest {
    my ($path) = @_;
    ordinary($path);
    open my $file, '<:raw', $path or die "$path: $!\n";
    return Digest::SHA->new(256)->addfile($file)->hexdigest;
}
sub archive_sha {
    my @rows = grep { /^libbacktrace\t/ } split /\n/, read_file("$vendor/dependencies.tsv");
    die "expected one pinned libbacktrace dependency\n" unless @rows == 1;
    my @fields = split /\t/, $rows[0];
    die "malformed pinned libbacktrace dependency\n"
        unless @fields == 5 && $fields[3] =~ /^[a-f0-9]{64}$/;
    return $fields[3];
}
sub receipt {
    my ($sha) = @_;
    return "format=1\narchive=$sha\npatch=" . digest($patch) . "\nalloc=$patched_sha\n";
}
sub write_receipt {
    my ($path, $text) = @_;
    if (-e $path || -l $path) {
        return if read_file($path) eq $text;
    }
    my ($file, $temporary) = tempfile('.titan-allocator-XXXXXX', DIR => dirname($path), UNLINK => 0);
    my $ok = eval {
        binmode $file, ':raw' or die "$temporary: $!\n";
        print {$file} $text or die "$temporary: $!\n";
        close $file or die "$temporary: $!\n";
        chmod 0644, $temporary or die "chmod $temporary: $!\n";
        rename $temporary, $path or die "publish $path: $!\n";
        1;
    };
    if (!$ok) {
        my $error = $@;
        close $file if defined fileno($file);
        unlink $temporary;
        die $error;
    }
}
sub prepare {
    my ($source, $sha) = @_;
    die "ordinary libbacktrace source directory required: $source\n" unless -d $source && !-l $source;
    die "libbacktrace archive identity does not match the pin\n" unless $sha eq archive_sha();
    my $receipt_path = "$source/$receipt_name";
    ordinary($receipt_path) if -e $receipt_path || -l $receipt_path;
    my $expected_receipt = receipt($sha);
    my $alloc = "$source/alloc.c";
    my $before = digest($alloc);
    die "unknown pinned libbacktrace alloc.c digest: $before\n"
        unless $before eq $original_sha || $before eq $patched_sha;
    if ($before eq $original_sha) {
        system('git', '-C', $source, 'apply', '--no-index', '--check', $patch) == 0
            or die "libbacktrace allocator patch does not match pinned source\n";
        system('git', '-C', $source, 'apply', '--no-index', $patch) == 0
            or die "libbacktrace allocator patch failed\n";
    }
    die "libbacktrace allocator patch produced an unexpected digest\n" unless digest($alloc) eq $patched_sha;
    system('git', '-C', $source, 'apply', '--no-index', '--reverse', '--check', $patch) == 0
        or die "libbacktrace allocator reverse check failed\n";
    write_receipt($receipt_path, $expected_receipt);
}
sub build_digest {
    my ($source) = @_;
    die "ordinary libbacktrace source directory required: $source\n" unless -d $source && !-l $source;
    my $sha = archive_sha();
    die "libbacktrace source completion does not match the pinned archive\n"
        unless read_file("$source/.titan-windows-source") eq "$sha\n";
    die "libbacktrace alloc.c is not the verified allocator source; run source preparation\n"
        unless digest("$source/alloc.c") eq $patched_sha;
    my $expected = receipt($sha);
    die "libbacktrace allocator receipt is missing or stale; run source preparation\n"
        unless read_file("$source/$receipt_name") eq $expected;
    return Digest::SHA::sha256_hex($expected) . "\n";
}
sub configured_source {
    my ($makefile) = @_;
    my @sources;
    my $continued = 0;
    for my $line (split /\n/, read_file($makefile)) {
        $line =~ s/\r\z//;
        push @sources, $1 if !$continued && $line =~ /^srcdir[ \t]*=[ \t]*(.*)\z/;
        # An odd run of trailing backslashes continues the logical Make line.
        # In particular, am__check_pre contains a column-zero srcdir shell
        # assignment which is not the configure-generated variable declaration.
        my $slashes = 0;
        ++$slashes while length($line) > $slashes && substr($line, -1 - $slashes, 1) eq chr(92);
        $continued = $slashes % 2;
    }
    die "expected one literal configured libbacktrace srcdir\n"
        unless @sources == 1 && length($sources[0]);
    die "configured libbacktrace srcdir contains unsupported Make syntax\n"
        if index($sources[0], q{$}) >= 0 || index($sources[0], q{#}) >= 0 || index($sources[0], chr(92)) >= 0;
    return $sources[0];
}
1;
