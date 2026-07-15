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
my $db = $h->app->sqlite->db;

sub insert_report (%args) {
    $db->query(<<~'SQL',
        INSERT INTO report (
            smoke_date, perl_id, git_id, git_describe,
            hostname, architecture, osname, osversion,
            summary, smoke_branch, plevel, report_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        $args{smoke_date},
        $args{perl_id},
        $args{git_id},
        $args{git_describe} // "v$args{perl_id}-1-g$args{git_id}",
        $args{hostname}     // 'testhost',
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.1',
        $args{summary}      // 'PASS',
        $args{smoke_branch} // 'blead',
        $args{plevel},
        $args{report_hash},
    );
}

insert_report(
    perl_id     => '5.40.0',
    plevel      => '5.040000zzz000',
    smoke_date  => '2024-01-01T10:00:00Z',
    git_id      => 'aaa1',
    report_hash => 'sp_aaa1',
);
insert_report(
    perl_id     => '5.41.9',
    plevel      => '5.041009zzz000',
    smoke_date  => '2024-03-01T10:00:00Z',
    git_id      => 'bbb1',
    report_hash => 'sp_bbb1',
);
insert_report(
    perl_id     => '5.42.0',
    plevel      => '5.042000zzz000',
    smoke_date  => '2024-06-01T10:00:00Z',
    git_id      => 'ccc1',
    report_hash => 'sp_ccc1',
);
insert_report(
    perl_id     => '5.39.10',
    plevel      => '5.039010zzz000',
    smoke_date  => '2024-01-15T10:00:00Z',
    git_id      => 'ddd1',
    report_hash => 'sp_ddd1',
);

my $sp = $h->app->reports->searchparameters;

is ref $sp->{perl_versions}, 'ARRAY', 'perl_versions is an array';
is scalar @{ $sp->{perl_versions} }, 4, 'four distinct perl versions';

is_deeply $sp->{perl_versions},
    [qw(5.42.0 5.41.9 5.40.0 5.39.10)],
    'perl_versions sorted descending by numeric version components';

my $api = $t->get_ok('/api/searchparameters')->status_is(200)->tx->res->json;
is_deeply $api->{perl_versions}, $sp->{perl_versions},
    'API endpoint returns same ordering as model';

done_testing;
