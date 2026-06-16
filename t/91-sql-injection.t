use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Mojo::Util qw(url_escape);

my $h = TestApp->new;
my $t = $h->t;

my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, "ingested report $resp->{id}";

# --- SQL injection payloads ---
# The search compiler uses parameterised binds (?), so none of these
# should break anything.  The definitive assertion is at the bottom:
# the report table is still intact and queryable after every attempt.

my @payloads = (
    "'; DROP TABLE report; --",
    "' OR 1=1 --",
    "' UNION SELECT sql FROM sqlite_master --",
    "1; DELETE FROM report",
    "' OR ''='",
    "'; UPDATE report SET hostname='pwned'; --",
);

# Text filters: each maps to a parameterised = ? or <> ? clause.
for my $field (qw(selected_arch selected_osnm selected_osvs selected_host
                  selected_branch selected_smkv selected_comp selected_cver)) {
    for my $payload (@payloads) {
        $t->get_ok('/api/searchresults?' . $field . '=' . url_escape($payload))
          ->status_is(200, "$field injection: $payload");
    }
}

# Summary filter (GLOB branch in compile).
for my $payload (@payloads) {
    $t->get_ok('/api/searchresults?selected_summary=' . url_escape($payload))
      ->status_is(200, "selected_summary injection: $payload");
}

# Date filters (>= / < date() clauses).
for my $field (qw(date_from date_to)) {
    for my $payload (@payloads) {
        $t->get_ok('/api/searchresults?' . $field . '=' . url_escape($payload))
          ->status_is(200, "$field injection: $payload");
    }
}

# Perl filter (= ? clause).
for my $payload (@payloads) {
    $t->get_ok('/api/searchresults?selected_perl=' . url_escape($payload))
      ->status_is(200, "selected_perl injection: $payload");
}

# Pagination params (int-cast, but verify).
$t->get_ok('/api/searchresults?page=' . url_escape("1; DROP TABLE report"))
  ->status_is(200, 'page injection');
$t->get_ok('/api/searchresults?reports_per_page=' . url_escape("25 OR 1=1"))
  ->status_is(200, 'rpp injection');

# Web /search route with the same payloads.
for my $payload (@payloads) {
    $t->get_ok('/search?hostname=' . url_escape($payload))
      ->status_is(200, "web /search injection: $payload");
}

# --- definitive integrity check ---
# If any injection had succeeded, this query would fail.
$t->get_ok('/api/searchresults')
  ->status_is(200)
  ->json_is('/report_count' => 1, 'report table intact after all injection attempts');

done_testing;
