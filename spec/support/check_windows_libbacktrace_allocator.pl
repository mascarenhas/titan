#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

# Host control fixture: execute the production source/preparation scripts and
# replace only native Make/cygpath. The native allocator harness owns C behavior.
my ($repo, $mode) = @ARGV;
die "usage: check_windows_libbacktrace_allocator.pl REPOSITORY prepare|build|native\n"
    unless @ARGV == 2 && $mode =~ /^(prepare|build|native)$/;
$repo = abs_path($repo) or die "repository is missing\n";
my $root = tempdir('titan-libbt-receipt-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $manifest = "$repo/vendor/libbacktrace/dependencies.tsv";
sub read_file {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "$path: $!\n";
    local $/; return (<$file> // '');
}
sub write_file {
    my ($path, $text) = @_;
    open my $file, '>:raw', $path or die "$path: $!\n";
    print {$file} $text or die "$path: $!\n";
    close $file or die "$path: $!\n";
}
sub check { die "$_[1]\n" unless $_[0]; }
my $serial = 0;
sub run_at {
    my ($cwd, @argv) = @_;
    my $output = "$root/output-" . ++$serial;
    my $pid = fork(); die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        chdir $cwd or die "chdir $cwd: $!\n";
        open STDOUT, '>:raw', $output or die "$output: $!\n";
        open STDERR, '>&', STDOUT or die "stderr: $!\n";
        exec {$argv[0]} @argv or die "exec $argv[0]: $!\n";
    }
    waitpid($pid, 0) == $pid or die "waitpid: $!\n";
    return ($? == 0, read_file($output));
}
sub must_run {
    my ($cwd, @argv) = @_;
    my ($ok, $output) = run_at($cwd, @argv);
    check($ok, "command failed (@argv):\n$output");
    return $output;
}
my ($name, $directory, $archive, $sha) = split /\t/, read_file($manifest);
check($name eq 'libbacktrace' && $sha =~ /^[a-f0-9]{64}$/, 'invalid pinned dependency');
my $source_root = "$root/source root";
my $source = "$source_root/$directory";
make_path($source);
for my $file (qw(alloc.c pecoff.c backtrace.h)) {
    copy("$repo/libbacktrace/$file", "$source/$file") or die "copy $file: $!\n";
}
my $original = read_file("$source/alloc.c");
must_run($root, 'git', '-C', $source, 'apply', '--no-index',
    "$repo/vendor/libbacktrace/libbacktrace-0b9b49c-windows-images.patch");
my $completion = "$source/.titan-windows-source";
my $receipt = "$source/.titan-windows-libbacktrace-allocator";
write_file($completion, "$sha\n");
write_file("$source/unrelated.txt", "unrelated source\n");
sub prepare_source {
    return run_at($root, 'perl', "$repo/scripts/prepare_windows_native.pl",
        $source_root, $manifest, 'system');
}
sub source_digest {
    # A different working directory also tests the module's own vendor lookup.
    return run_at($root, 'perl', '-I', "$repo/scripts", '-MWindowsLibbacktraceAllocator',
        '-e', 'print WindowsLibbacktraceAllocator::build_digest($ARGV[0])', $source);
}
my ($prepared, $output) = prepare_source();
check($prepared, "legacy source upgrade failed: $output");
my $patched = read_file("$source/alloc.c");
my $expected = "format=1\narchive=$sha\npatch=" .
    sha256_hex(read_file("$repo/vendor/libbacktrace/libbacktrace-0b9b49c-alloc-growth.patch")) .
    "\nalloc=" . sha256_hex($patched) . "\n";
check($patched ne $original && read_file($receipt) eq $expected, 'source receipt does not describe patched bytes');
my $key = sha256_hex($expected) . "\n";
my ($key_ok, $key_output) = source_digest();
check($key_ok && $key_output eq $key, "verified source key failed: $key_output");

if ($mode eq 'native') {
    # Linux normally selects mmap.c. Force only this verified alloc.c into the
    # regression harness; do not rebuild or replace the host runtime archive.
    write_file("$root/original-alloc.c", $original);
    my ($ok, $native_output) = run_at($root, 'bash',
        "$repo/spec/support/check_libbacktrace_allocator.sh", "$source/alloc.c",
        "$repo/libbacktrace", "$repo/libbacktrace", "$root/native controls",
        "$root/original-alloc.c");
    check($ok, "forced alloc.c control failed: $native_output");
    check($native_output =~ /Actual-source allocator regression passed at O0 and O2[.]/,
        "missing optimized/unoptimized native control result: $native_output");
    print $native_output;
    print "Forced alloc.c native controls passed without replacing the host mmap archive.\n";
    exit 0;
}

if ($mode eq 'prepare') {
    # This archive/manifest pin is synthetic. Only the acquisition container
    # changes: copied production scripts, patches and pinned C bytes stay exact.
    my $fixture = "$root/fresh fixture";
    make_path("$fixture/scripts", "$fixture/vendor/libbacktrace", "$fixture/payload/$directory", "$fixture/tools");
    for my $file (qw(prepare_windows_native.pl WindowsLibbacktraceAllocator.pm)) {
        copy("$repo/scripts/$file", "$fixture/scripts/$file") or die "copy implementation: $!\n";
    }
    for my $file (qw(libbacktrace-0b9b49c-windows-images.patch libbacktrace-0b9b49c-alloc-growth.patch)) {
        copy("$repo/vendor/libbacktrace/$file", "$fixture/vendor/libbacktrace/$file") or die "copy patch: $!\n";
    }
    for my $file (qw(alloc.c pecoff.c backtrace.h)) {
        copy("$repo/libbacktrace/$file", "$fixture/payload/$directory/$file") or die "copy pinned source: $!\n";
    }
    write_file("$fixture/tools/curl", "#!/bin/sh\necho 'fixture forbids downloads' >&2\nexit 88\n");
    chmod 0755, "$fixture/tools/curl" or die "chmod fixture curl: $!\n";
    my $fixture_archive = "$fixture/source-fixture.tar.gz";
    must_run($root, 'tar', '-czf', $fixture_archive, '-C', "$fixture/payload", $directory);
    my $archive_bytes = read_file($fixture_archive);
    my $fixture_sha = sha256_hex($archive_bytes);
    my $fixture_manifest = "$fixture/vendor/libbacktrace/dependencies.tsv";
    write_file($fixture_manifest, "libbacktrace\t$directory\tsource-fixture.tar.gz\t$fixture_sha\thttps://example.invalid/fixture-no-download\n");
    my $fresh = "$fixture/sources-success";
    my $fresh_prepare = sub {
        my ($destination) = @_;
        local $ENV{PATH} = "$fixture/tools:$ENV{PATH}";
        return run_at($fixture, 'perl', "$fixture/scripts/prepare_windows_native.pl", $destination, $fixture_manifest, 'system');
    };
    my ($fresh_ok, $fresh_output) = $fresh_prepare->($fresh);
    check($fresh_ok, "fresh synthetic acquisition failed: $fresh_output");
    my $published = "$fresh/$directory";
    check(read_file("$published/alloc.c") eq $patched && read_file("$published/.titan-windows-source") eq "$fixture_sha\n",
        'fresh acquisition did not publish checked source and completion');
    my $fresh_expected = $expected;
    $fresh_expected =~ s/archive=\Q$sha\E/archive=$fixture_sha/;
    check(read_file("$published/.titan-windows-libbacktrace-allocator") eq $fresh_expected,
        'fresh acquisition did not publish its checked allocator receipt');
    my %fresh_before;
    for my $file (qw(alloc.c pecoff.c .titan-windows-source .titan-windows-libbacktrace-allocator)) {
        utime(946684800, 946684800, "$published/$file") == 1 or die "utime fresh: $!\n";
        $fresh_before{$file} = [read_file("$published/$file"), (stat("$published/$file"))[9]];
    }
    ($fresh_ok, $fresh_output) = $fresh_prepare->($fresh);
    check($fresh_ok, "fresh acquisition repeat failed: $fresh_output");
    for my $file (keys %fresh_before) {
        check(read_file("$published/$file") eq $fresh_before{$file}[0] && (stat("$published/$file"))[9] == $fresh_before{$file}[1],
            "fresh repeat changed bytes or mtime: $file");
    }
    write_file($fixture_archive, $archive_bytes . 'corrupt archive');
    ($fresh_ok, $fresh_output) = $fresh_prepare->("$fixture/sources-bad-archive");
    check(!$fresh_ok && !-e "$fixture/sources-bad-archive/$directory", 'bad archive published a source destination');
    write_file($fixture_archive, $archive_bytes);
    write_file("$fixture/vendor/libbacktrace/libbacktrace-0b9b49c-alloc-growth.patch", "invalid allocator patch\n");
    ($fresh_ok, $fresh_output) = $fresh_prepare->("$fixture/sources-bad-patch");
    check(!$fresh_ok && !-e "$fixture/sources-bad-patch/$directory", 'bad allocator patch published a source destination');

    my @files = ($completion, $receipt, "$source/alloc.c", "$source/pecoff.c", "$source/unrelated.txt");
    my %before;
    my $time = 946684800;
    for my $file (@files) {
        utime($time, $time, $file) == 1 or die "utime: $!\n";
        $before{$file} = [read_file($file), (stat($file))[9]];
        ++$time;
    }
    ($prepared, $output) = prepare_source();
    check($prepared, "repeat preparation failed: $output");
    for my $file (@files) {
        check(read_file($file) eq $before{$file}[0] && (stat($file))[9] == $before{$file}[1],
            "repeat preparation changed bytes or mtime: $file");
    }
    write_file("$source/alloc.c", $original);
    ($key_ok, $key_output) = source_digest();
    check(!$key_ok, 'direct build accepted restored unpatched source');
    ($prepared, $output) = prepare_source();
    check($prepared && read_file("$source/alloc.c") eq $patched, "restored source was not upgraded: $output");
    write_file("$source/alloc.c", $patched . "/* unknown bytes */\n");
    ($prepared, $output) = prepare_source();
    check(!$prepared && read_file($receipt) eq $expected && read_file($completion) eq "$sha\n",
        'unknown source was accepted or published a receipt');
    ($key_ok, $key_output) = source_digest();
    check(!$key_ok, 'direct build accepted unknown source');
    write_file("$source/alloc.c", $patched);
    write_file($receipt, "stale receipt\n");
    ($key_ok, $key_output) = source_digest();
    check(!$key_ok, 'direct build accepted stale allocator receipt');
    ($prepared, $output) = prepare_source();
    check($prepared && read_file($receipt) eq $expected, "stale receipt was not repaired: $output");
    write_file($completion, "wrong archive\n");
    ($prepared, $output) = prepare_source();
    check(!$prepared && read_file($receipt) eq $expected, 'wrong archive identity was accepted');
    ($key_ok, $key_output) = source_digest();
    check(!$key_ok, 'direct build accepted wrong archive completion');
    write_file($completion, "$sha\n");
    unlink $receipt or die "unlink receipt: $!\n";
    symlink('missing-target', $receipt) or die "symlink receipt: $!\n";
    ($prepared, $output) = prepare_source();
    check(!$prepared && -l $receipt && read_file("$source/alloc.c") eq $patched,
        'preparation accepted a symlink receipt');
    ($key_ok, $key_output) = source_digest();
    check(!$key_ok, 'direct build accepted a symlink receipt');
    print "Windows allocator source preparation controls passed.\n";
    exit 0;
}

my $work = "$root/build root";
my $prefix = "$root/prefix root";
my $tools = "$root/tools";
make_path("$work/.libs", $tools, $prefix);
write_file("$tools/cygpath", "#!/bin/sh\ncase \"\$1\" in -m|-u) ;; *) exit 20 ;; esac\nprintf '%s\\n' \"\$2\"\n");
write_file("$tools/fake-make", <<'SH');
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -C ]]
work=$2
printf '%s\n' "$FIXTURE_MODE" >> "$FIXTURE_LOG"
for file in dwarf.o config.status Makefile backtrace-supported.h; do
  IFS= read -r first < "$work/$file"
  first=${first%$'\r'}
  [[ $first == "unrelated:$file" ]] || exit 21
done
if [[ $FIXTURE_MODE == noop ]]; then
  for file in alloc.o alloc.lo .libs/alloc.o .libs/libbacktrace.a libbacktrace.la; do
    [[ -f $work/$file ]] || exit 22
  done
  exit 0
fi
for file in alloc.o alloc.lo .libs/alloc.o .libs/libbacktrace.a libbacktrace.la; do
  [[ ! -e $work/$file && ! -L $work/$file ]] || exit 23
done
[[ $FIXTURE_MODE != failure ]] || exit 7
[[ $FIXTURE_MODE != missing ]] || exit 0
if [[ $FIXTURE_MODE == symlink ]]; then
  ln -s "$work/dwarf.o" "$work/.libs/libbacktrace.a"
  exit 0
fi
for file in alloc.o alloc.lo .libs/alloc.o .libs/libbacktrace.a libbacktrace.la; do
  printf 'rebuilt:%s\n' "$file" > "$work/$file"
done
if [[ $FIXTURE_MODE == tamper ]]; then
  printf '/* changed during Make */\n' >> "$FIXTURE_SOURCE/alloc.c"
fi
SH
chmod 0755, "$tools/cygpath", "$tools/fake-make" or die "chmod tools: $!\n";
local $ENV{MSYSTEM} = 'CLANG64';
local $ENV{TITAN_BUILD_PROFILE} = 'validation';
local $ENV{MAKE} = "$tools/fake-make";
local $ENV{PATH} = "$tools:$ENV{PATH}";
local $ENV{FIXTURE_SOURCE} = $source;
local $ENV{FIXTURE_LOG} = "$root/make-calls";
my @allocator_files = qw(alloc.o alloc.lo .libs/alloc.o .libs/libbacktrace.a libbacktrace.la);
my @unrelated_files = qw(dwarf.o config.status Makefile backtrace-supported.h);
# Keep the actual Automake recipes: am__check_pre has a continued, column-zero
# shell srcdir assignment which must not become a second configure declaration.
my $generated_makefile = read_file("$repo/libbacktrace/Makefile");
check(index($generated_makefile, 'srcdir=$(srcdir); export srcdir;') >= 0,
    'generated Makefile does not contain the continued srcdir recipe control');
my $selected_source = abs_path($source);
my $declarations = ($generated_makefile =~ s/^srcdir = [^\n]*$/srcdir = $selected_source/mg);
check($declarations == 1, 'generated Makefile must have exactly one literal srcdir declaration');
my %unrelated;
for my $file (@unrelated_files) {
    my $contents = "unrelated:$file\n";
    $contents .= $generated_makefile if $file eq 'Makefile';
    write_file("$work/$file", $contents);
    utime(946684800, 946684800, "$work/$file") == 1 or die "utime unrelated: $!\n";
    $unrelated{$file} = [read_file("$work/$file"), (stat("$work/$file"))[9]];
}
sub check_unrelated {
    for my $file (@unrelated_files) {
        check(read_file("$work/$file") eq $unrelated{$file}[0] &&
            (stat("$work/$file"))[9] == $unrelated{$file}[1], "unrelated build input changed: $file");
    }
}
sub seed_objects {
    for my $file (@allocator_files) {
        unlink "$work/$file" if -l "$work/$file";
        write_file("$work/$file", "old:$file\n");
    }
}
sub build {
    my ($mode) = @_;
    local $ENV{FIXTURE_MODE} = $mode;
    return run_at($root, 'bash', "$repo/scripts/build_windows_libbacktrace.sh", $source, $work, $prefix);
}
my $built_receipt = "$work/.titan-libbacktrace-allocator-build";
seed_objects();
my ($built, $build_output) = build('rebuild');
check($built && read_file($built_receipt) eq $key, "missing-key rebuild failed: $build_output");
check_unrelated();
my %no_op;
for my $file ($built_receipt, map { "$work/$_" } @allocator_files) {
    utime(946684800, 946684800, $file) == 1 or die "utime noop: $!\n";
    $no_op{$file} = [read_file($file), (stat($file))[9]];
}
($built, $build_output) = build('noop');
check($built, "matching-key build failed: $build_output");
for my $file (keys %no_op) {
    check(read_file($file) eq $no_op{$file}[0] && (stat($file))[9] == $no_op{$file}[1],
        "matching-key build invalidated an output: $file");
}
check_unrelated();
my $crlf_makefile = $unrelated{Makefile}[0];
$crlf_makefile =~ s/\n/\r\n/g;
write_file("$work/Makefile", $crlf_makefile);
($built, $build_output) = build('noop');
check($built && read_file("$work/Makefile") eq $crlf_makefile,
    "CRLF generated Makefile ownership check failed: $build_output");
write_file("$work/Makefile", $unrelated{Makefile}[0]);
utime($unrelated{Makefile}[1], $unrelated{Makefile}[1], "$work/Makefile") == 1 or die "restore LF Makefile mtime: $!\n";
write_file($built_receipt, "different key\n"); seed_objects();
($built, $build_output) = build('rebuild');
check($built && read_file($built_receipt) eq $key, "different-key rebuild failed: $build_output");
check_unrelated();
my $installed = read_file("$prefix/lib/libbacktrace.a");
my $other_source = "$root/different source";
make_path($other_source);
write_file("$work/Makefile", "unrelated:Makefile\nsrcdir = " . abs_path($other_source) . "\n");
write_file($built_receipt, "previous configured source\n");
seed_objects();
my %mismatch;
for my $file ($built_receipt, "$work/Makefile", map { "$work/$_" } @allocator_files) {
    utime(946684800, 946684800, $file) == 1 or die "utime mismatch: $!\n";
    $mismatch{$file} = [read_file($file), (stat($file))[9]];
}
my $before_mismatch_calls = read_file($ENV{FIXTURE_LOG});
($built, $build_output) = build('rebuild');
check(!$built && read_file($ENV{FIXTURE_LOG}) eq $before_mismatch_calls,
    'builder reached Make for a differently configured source');
for my $file (keys %mismatch) {
    check(-f $file && read_file($file) eq $mismatch{$file}[0] &&
        (stat($file))[9] == $mismatch{$file}[1], "source mismatch invalidated an output: $file");
}
check(read_file("$prefix/lib/libbacktrace.a") eq $installed, 'source mismatch published a prefix archive');
write_file("$work/Makefile", $unrelated{Makefile}[0]);
utime($unrelated{Makefile}[1], $unrelated{Makefile}[1], "$work/Makefile") == 1 or die "restore Makefile mtime: $!\n";
for my $failure (qw(failure missing symlink tamper)) {
    write_file($built_receipt, "previous:$failure\n");
    utime(946684800, 946684800, $built_receipt) == 1 or die "utime old receipt: $!\n";
    seed_objects();
    ($built, $build_output) = build($failure);
    check(!$built && read_file($built_receipt) eq "previous:$failure\n" &&
        (stat($built_receipt))[9] == 946684800, "$failure published a build receipt: $build_output");
    check(read_file("$prefix/lib/libbacktrace.a") eq $installed, "$failure published a prefix archive");
    check_unrelated();
    write_file("$source/alloc.c", $patched);
}
my $calls = read_file($ENV{FIXTURE_LOG});
for my $bad ($original, $patched . "/* unknown bytes */\n") {
    write_file("$source/alloc.c", $bad);
    ($built, $build_output) = build('rebuild');
    check(!$built && read_file($ENV{FIXTURE_LOG}) eq $calls,
        'direct builder reached Make with unpatched or unknown source');
}
write_file("$source/alloc.c", $patched);
unlink $built_receipt or die "unlink build receipt: $!\n";
symlink('missing-target', $built_receipt) or die "symlink build receipt: $!\n";
($built, $build_output) = build('rebuild');
check(!$built && -l $built_receipt && read_file($ENV{FIXTURE_LOG}) eq $calls,
    'builder accepted a nonordinary receipt');
print "Windows allocator archive-build controls passed.\n";
