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

# ---- Ingest the FAIL fixture ----
my $resp = $h->ingest_fixture('fail-report.jsn');
ok $resp->{id}, "FAIL fixture ingested (id=$resp->{id})";
my $rid = $resp->{id};

# ---- DB row has correct summary and hostname ----
my $row = $h->app->sqlite->db->query(
    "SELECT summary, hostname, plevel FROM report WHERE id = ?", $rid
)->hash;
is $row->{summary},  'FAIL(F)', 'summary stored as FAIL(F)';
is $row->{hostname}, 'failbox', 'hostname flattened from sysinfo';
like $row->{plevel}, qr/^5\./, 'plevel computed';

# ---- Configs, results, and failures persisted ----
my $configs = $h->app->sqlite->db->query(
    "SELECT id, arguments, debugging FROM config WHERE report_id = ? ORDER BY id",
    $rid
)->hashes->to_array;
is scalar(@$configs), 2, '2 configs inserted';

my $cfg1_results = $h->app->sqlite->db->query(
    "SELECT id, summary, io_env FROM result WHERE config_id = ? ORDER BY id",
    $configs->[0]{id}
)->hashes->to_array;
is scalar(@$cfg1_results), 3, 'config 1 has 3 results';
is $cfg1_results->[0]{summary}, 'F', 'config1/stdio summary is F';
is $cfg1_results->[1]{summary}, 'O', 'config1/perlio summary is O (pass)';
is $cfg1_results->[2]{summary}, 'F', 'config1/locale summary is F';

my $cfg2_results = $h->app->sqlite->db->query(
    "SELECT id, summary FROM result WHERE config_id = ? ORDER BY id",
    $configs->[1]{id}
)->hashes->to_array;
is $cfg2_results->[0]{summary}, 'O', 'config2/stdio passes (debugging build)';

# failures_for_env links exist for the two failing results
my $fail_links = $h->app->sqlite->db->query(
    "SELECT COUNT(*) AS n FROM failures_for_env WHERE result_id IN (?, ?)",
    $cfg1_results->[0]{id}, $cfg1_results->[2]{id}
)->hash;
ok $fail_links->{n} >= 2, 'failure links exist for failing results';

# ---- On-disk files written ----
my $rf = $h->app->report_files;
ok defined $rf->read($rid, 'log_file'),      'log_file written to disk';
ok defined $rf->read($rid, 'out_file'),       'out_file written to disk';
ok defined $rf->read($rid, 'compiler_msgs'),  'compiler_msgs written to disk';
ok defined $rf->read($rid, 'nonfatal_msgs'),  'nonfatal_msgs written to disk';
like $rf->read($rid, 'log_file'), qr/Failed 2 tests/, 'log_file content correct';
like $rf->read($rid, 'out_file'), qr/Compiler output/, 'out_file content correct';

# ---- API: /api/full_report_data includes failure data ----
$t->get_ok("/api/full_report_data/$rid")->status_is(200)
  ->json_has('/test_failures')
  ->json_has('/matrix_rows')
  ->json_has('/c_compilers')
  ->json_has('/has_log_file')
  ->json_has('/has_out_file');

my $full = $t->tx->res->json;
ok $full->{has_log_file},  'has_log_file is true';
ok $full->{has_out_file},  'has_out_file is true';
like $full->{compiler_msgs_text}, qr/unused variable/, 'compiler_msgs_text from disk';
like $full->{nonfatal_msgs_text}, qr/non-fatal warning/, 'nonfatal_msgs_text from disk';

# test_failures grouped correctly
my @tf = @{ $full->{test_failures} // [] };
ok scalar(@tf) >= 2, 'at least 2 distinct failing tests';
my %by_test = map { $_->{test} => $_ } @tf;
ok $by_test{'op/magic.t'},  'op/magic.t in test_failures';
ok $by_test{'io/pipe.t'},   'io/pipe.t in test_failures';
is $by_test{'op/magic.t'}{status}, 'FAILED', 'op/magic.t status is FAILED';
ok scalar(@{ $by_test{'op/magic.t'}{configs} }) >= 2,
   'op/magic.t fails across multiple configs (stdio + locale)';

# matrix_rows present with mixed pass/fail
my @rows = @{ $full->{matrix_rows} // [] };
ok scalar(@rows) >= 2, 'matrix_rows has rows for both configs';
my @summaries = map { $_->{summary} } map { @{ $_->{results} // [] } } @rows;
ok(scalar(grep { $_ eq 'F' } @summaries), 'matrix has F summaries');
ok(scalar(grep { $_ eq 'O' } @summaries), 'matrix has O summaries');

# ---- Web: /report/:rid renders failure panel ----
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/op\/magic\.t/,  'report page shows failing test name')
  ->content_like(qr/io\/pipe\.t/,   'report page shows second failing test')
  ->content_like(qr/FAILED/,        'report page shows failure status')
  ->content_like(qr/FAIL\(F\)/,     'report page shows FAIL(F) summary');

# log_file and out_file links present
$t->get_ok("/report/$rid")->status_is(200)
  ->element_exists("a[href='/file/log_file/$rid']",  'log_file link present')
  ->element_exists("a[href='/file/out_file/$rid']",  'out_file link present');

# ---- Web: /file/* serves the on-disk content ----
$t->get_ok("/file/log_file/$rid")->status_is(200)
  ->content_like(qr/Failed 2 tests/, 'log_file content served');
$t->get_ok("/file/out_file/$rid")->status_is(200)
  ->content_like(qr/Compiler output/, 'out_file content served');

# ---- Web: /latest shows the FAIL report ----
$t->get_ok('/latest')->status_is(200)
  ->content_like(qr/failbox/, 'latest page shows failbox hostname');

# /latest with fail filter includes the report
$t->get_ok('/latest?selected_summary=fail')->status_is(200)
  ->content_like(qr/failbox/, 'fail filter includes failbox');

# /latest with pass filter excludes the report
$t->get_ok('/latest?selected_summary=pass')->status_is(200)
  ->content_unlike(qr/failbox/, 'pass filter excludes failbox');

# ---- Web: /search finds the FAIL report by summary filter ----
$t->get_ok('/search?selected_summary=FAIL(*)')->status_is(200)
  ->content_like(qr/failbox/, 'search FAIL(*) finds failbox');
$t->get_ok('/search?selected_summary=FAIL(F)')->status_is(200)
  ->content_like(qr/failbox/, 'search FAIL(F) finds failbox');

# /search by hostname filter
$t->get_ok('/search?selected_hostname=failbox')->status_is(200)
  ->content_like(qr/failbox/, 'search by hostname finds failbox');

# ---- Web: /matrix includes the failing test ----
$t->get_ok('/matrix')->status_is(200)
  ->content_like(qr/op\/magic\.t/, 'matrix page shows failing test op/magic.t');

# ---- API: /api/searchresults with FAIL filter ----
$t->get_ok('/api/searchresults?selected_summary=FAIL(*)')->status_is(200);
my $sr = $t->tx->res->json;
ok $sr->{report_count} >= 1, 'API search FAIL(*) returns at least 1 result';
my @fail_reports = grep { $_->{hostname} eq 'failbox' }
    @{ $sr->{reports} // [] };
ok scalar(@fail_reports), 'failbox appears in FAIL(*) search results';

# ---- Duplicate detection works for FAIL fixture too ----
$t->post_ok('/api/report', json => {
    report_data => $h->fixture('fail-report.jsn')
})->status_is(409)->json_is('/error' => 'Report already posted.');

done_testing;
