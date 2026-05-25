use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;

my $h  = TestApp->new;
my $t  = $h->t;
my $db = $h->app->sqlite->db;

# Seed: two reports -- one PASS, one FAIL -- so we can test selected_summary
sub insert_report (%args) {
    $db->query(<<~'SQL',
        INSERT INTO report (
            smoke_date, perl_id, git_id, git_describe,
            hostname, architecture, osname, osversion,
            summary, smoke_branch, plevel, report_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        $args{smoke_date},
        $args{perl_id}      // '5.42.0',
        $args{git_id},
        $args{git_describe} // 'v5.42.0-1-g' . $args{git_id},
        $args{hostname},
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.5',
        $args{summary},
        $args{smoke_branch} // 'blead',
        $args{plevel}       // '5.042000zzz000',
        $args{report_hash},
    );
    return $db->dbh->last_insert_id(undef, undef, 'report', undef);
}

my $rid_pass = insert_report(
    hostname    => 'host-pass',
    git_id      => 'pass0001',
    smoke_date  => '2024-08-01T10:00:00Z',
    summary     => 'PASS',
    report_hash => 'hash_pass_001',
);

my $rid_fail = insert_report(
    hostname    => 'host-fail',
    git_id      => 'fail0001',
    smoke_date  => '2024-08-02T10:00:00Z',
    summary     => 'FAIL(F)',
    report_hash => 'hash_fail_001',
);

# =========================================================================
# /api/latest?selected_summary=pass|fail|all
# =========================================================================

subtest 'REST /api/latest selected_summary filter' => sub {
    my $all = $t->get_ok('/api/latest')->status_is(200)->tx->res->json;
    is $all->{report_count}, 2, 'no filter returns both';

    my $pass = $t->get_ok('/api/latest?selected_summary=pass')
        ->status_is(200)->tx->res->json;
    is $pass->{report_count}, 1, 'pass filter returns 1';
    is $pass->{reports}[0]{hostname}, 'host-pass', 'pass filter returns PASS host';

    my $fail = $t->get_ok('/api/latest?selected_summary=fail')
        ->status_is(200)->tx->res->json;
    is $fail->{report_count}, 1, 'fail filter returns 1';
    is $fail->{reports}[0]{hostname}, 'host-fail', 'fail filter returns FAIL host';
};

subtest 'JSONRPC latest selected_summary filter' => sub {
    my $res = $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 1,
        method  => 'latest',
        params  => { selected_summary => 'pass' },
    })->status_is(200)->tx->res->json;
    is $res->{result}{report_count}, 1, 'JSONRPC pass filter returns 1';
    is $res->{result}{reports}[0]{hostname}, 'host-pass', 'JSONRPC pass filter correct host';
};

# =========================================================================
# /api/matrix?include_stdio=1
# =========================================================================

# Seed a failure in a stdio result to test the filter.
my $rid_stdio = insert_report(
    hostname    => 'host-stdio',
    git_id      => 'stdi0001',
    smoke_date  => '2024-08-03T10:00:00Z',
    summary     => 'FAIL(F)',
    report_hash => 'hash_stdio_001',
    plevel      => '5.042000zzz001',
);

$db->query("INSERT INTO config (report_id, arguments, debugging) VALUES (?, '', 'N')", $rid_stdio);
my $cid = $db->dbh->last_insert_id(undef, undef, 'config', undef);

$db->query("INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'F')", $cid);
my $stdio_resid = $db->dbh->last_insert_id(undef, undef, 'result', undef);

$db->query("INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F')", $cid);
my $perlio_resid = $db->dbh->last_insert_id(undef, undef, 'result', undef);

$db->query("INSERT INTO failure (test, status, extra) VALUES ('stdio/only.t', 'FAILED', '')");
my $fid_stdio = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query("INSERT INTO failure (test, status, extra) VALUES ('perlio/only.t', 'FAILED', '')");
my $fid_perlio = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $stdio_resid, $fid_stdio);
$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $perlio_resid, $fid_perlio);

subtest 'REST /api/matrix include_stdio' => sub {
    my $default = $t->get_ok('/api/matrix')->status_is(200)->tx->res->json;
    my @tests = map { $_->{test} } @{ $default->{rows} };
    ok !(grep { $_ eq 'stdio/only.t' } @tests),
        'stdio failure excluded by default';
    ok  (grep { $_ eq 'perlio/only.t' } @tests),
        'perlio failure always present';

    my $with_stdio = $t->get_ok('/api/matrix?include_stdio=1')
        ->status_is(200)->tx->res->json;
    my @tests_s = map { $_->{test} } @{ $with_stdio->{rows} };
    ok (grep { $_ eq 'stdio/only.t' } @tests_s),
        'stdio failure included when include_stdio=1';
};

subtest 'JSONRPC matrix include_stdio' => sub {
    my $res = $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 2,
        method  => 'matrix',
        params  => { include_stdio => 1 },
    })->status_is(200)->tx->res->json;
    my @tests = map { $_->{test} } @{ $res->{result}{rows} };
    ok (grep { $_ eq 'stdio/only.t' } @tests),
        'JSONRPC matrix with include_stdio shows stdio failure';
};

done_testing;
