use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;

my $h = TestApp->new;
my $t = $h->t;

# --- Path traversal and malicious :rid on /file/* routes ---
#
# The :rid placeholder feeds into a parameterized SQL query
# (WHERE id = ?), so non-integer values return no rows -> 404.
# The file path is constructed from report_hash (a DB column),
# never from :rid directly. These tests document that boundary.

my @file_routes = qw( /file/log_file /file/out_file );

for my $base (@file_routes) {

    # Path traversal attempts
    $t->get_ok("$base/../../etc/passwd")->status_is(404,
        "$base rejects directory traversal");

    # URL-encoded traversal
    $t->get_ok("$base/1%2F..%2F..%2Fetc%2Fpasswd")->status_is(404,
        "$base rejects URL-encoded traversal");

    # Double-encoded traversal
    $t->get_ok("$base/1%252F..%252F..%252Fetc%252Fpasswd")->status_is(404,
        "$base rejects double-encoded traversal");

    # Non-integer strings
    $t->get_ok("$base/abc")->status_is(404,
        "$base rejects non-integer rid");

    # Negative and zero
    $t->get_ok("$base/-1")->status_is(404,
        "$base rejects negative rid");
    $t->get_ok("$base/0")->status_is(404,
        "$base rejects zero rid");

    # Very large number (no matching row)
    $t->get_ok("$base/999999999")->status_is(404,
        "$base returns 404 for non-existent large rid");

    # SQL injection in rid (parameterized query makes this inert)
    $t->get_ok("$base/1 OR 1=1")->status_is(404,
        "$base rejects SQL injection attempt");
    $t->get_ok("$base/1;DROP TABLE report")->status_is(404,
        "$base rejects SQL drop attempt");

    # Null bytes
    $t->get_ok("$base/1%00etc/passwd")->status_is(404,
        "$base rejects null byte injection");
}

# --- Verify /report/:rid has the same boundary ---

$t->get_ok('/report/../../etc/passwd')->status_is(404,
    '/report rejects directory traversal');
$t->get_ok('/report/abc')->status_is(404,
    '/report rejects non-integer rid');
$t->get_ok('/report/1 OR 1=1')->status_is(404,
    '/report rejects SQL injection attempt');

# --- API outfile routes share the same safety ---

for my $api_base (qw( /api/outfile /api/outfle )) {
    $t->get_ok("$api_base/../../etc/passwd")->status_is(404,
        "$api_base rejects directory traversal");
    $t->get_ok("$api_base/abc")->status_is(404,
        "$api_base rejects non-integer rid");
}

done_testing;
