#!/usr/bin/env perl
# OpenHarmony patch for sing common/control/bind_linux.go:
# ByName failure must NOT fall back to SO_BINDTODEVICE (needs CAP_NET_RAW -> EPERM
# in app sandbox). Use the pre-resolved interface index (SING_BOX_BIND_IFINDEX)
# with SO_BINDTOIFINDEX (unprivileged) instead. Also ensures the strconv import.
use strict;
use warnings;

my $file = $ARGV[0] or die "usage: sing-bind-fallback.pl <bind_linux.go>\n";
open my $in, '<', $file or die "open: $!\n";
local $/;
my $c = <$in>;
close $in;

if (index($c, 'SING_BOX_BIND_IFINDEX') >= 0) {
    print "already patched\n";
    exit 0;
}

# v0.8.14 bind_linux.go uses 4-level indentation inside Raw(conn, func(fd) { if ... {
my $find = "\t\t\t\tiif, err := finder.ByName(interfaceName)\n"
    . "\t\t\t\tif err != nil {\n"
    . "\t\t\t\t\treturn err\n"
    . "\t\t\t\t}";

if (index($c, $find) < 0) {
    print STDERR "pattern not found\n";
    exit 1;
}

my $repl = "\t\t\t\tiif, err := finder.ByName(interfaceName)\n"
    . "\t\t\t\tif err != nil {\n"
    . "\t\t\t\t\t// OpenHarmony: BindToDevice requires CAP_NET_RAW (EPERM in app sandbox); use pre-resolved index if available\n"
    . "\t\t\t\t\tif idxStr := os.Getenv(\"SING_BOX_BIND_IFINDEX\"); idxStr != \"\" {\n"
    . "\t\t\t\t\t\tif idx, idxErr := strconv.Atoi(idxStr); idxErr == nil && idx > 0 {\n"
    . "\t\t\t\t\t\t\treturn unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_BINDTOIFINDEX, idx)\n"
    . "\t\t\t\t\t\t}\n"
    . "\t\t\t\t\t}\n"
    . "\t\t\t\t\treturn err\n"
    . "\t\t\t\t}";

$c =~ s/\Q$find\E/$repl/;

if (index($c, '"strconv"') < 0) {
    $c =~ s/\t"os"\n/\t"os"\n\t"strconv"\n/;
}

open my $out, '>', $file or die "write: $!\n";
print $out $c;
close $out;
print "sing bind fallback patched (index-based)\n";
