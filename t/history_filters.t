use strict;
use warnings;
use Test::More;

use DBI;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use lib 'lib';
use Plugins::ShazamCapture::History;

my $root = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($root, 'var', 'backups'));
Plugins::ShazamCapture::History::init($root, 'history.sqlite3');

Plugins::ShazamCapture::History::record(
	'00:11:22:33:44:55',
	1,
	{
		ok => 1,
		matched => 1,
		stale => 0,
		track => {
			title => 'First Song',
			artist => 'Example Artist',
			shazam_key => 'first',
		},
	},
	{ recognized_at => 1000 },
	'manual',
	{
		api_source => 'Plugins::LikedSongs',
		api_reason => 'like',
	},
);
Plugins::ShazamCapture::History::record(
	'00:11:22:33:44:55',
	2,
	{
		ok => 1,
		matched => 1,
		stale => 0,
		track => {
			title => 'Second Song',
			artist => 'Example Artist',
			shazam_key => 'second',
		},
	},
	{ recognized_at => 2000 },
	'manual',
	{
		api_source => 'Plugins::Bookmarks',
		api_reason => 'save',
	},
);

my $source_rows = Plugins::ShazamCapture::History::all_matches({
	filter_field => 'api_source',
	filter_value => 'likedsongs',
});
is(scalar @$source_rows, 1, 'filters active history by API caller');
is($source_rows->[0]->{title}, 'First Song', 'API caller filter finds expected row');

my $reason_rows = Plugins::ShazamCapture::History::all_matches({
	filter_field => 'api_reason',
	filter_value => 'SAVE',
});
is(scalar @$reason_rows, 1, 'filters API reason case-insensitively');
is($reason_rows->[0]->{title}, 'Second Song', 'API reason filter finds expected row');

my $legacy_path = File::Spec->catfile(
	$root, 'var', 'backups', 'legacy.sqlite3'
);
my $legacy = DBI->connect(
	"dbi:SQLite:dbname=$legacy_path", '', '',
	{ RaiseError => 1, PrintError => 0, AutoCommit => 1 },
);
$legacy->do(<<'SQL');
CREATE TABLE recognition_history (
	id INTEGER PRIMARY KEY,
	recognized_at INTEGER,
	player_id TEXT,
	generation INTEGER,
	ok INTEGER,
	matched INTEGER,
	title TEXT,
	artist TEXT,
	album TEXT,
	shazam_key TEXT,
	player_name TEXT,
	source_name TEXT,
	source_url TEXT,
	technical_source TEXT,
	apple_music_url TEXT,
	spotify_url TEXT,
	artwork_url TEXT,
	shazam_url TEXT,
	trigger_method TEXT
)
SQL
$legacy->do(
	'INSERT INTO recognition_history '
	. '(id,recognized_at,player_id,generation,ok,matched,title,trigger_method) '
	. 'VALUES (1,1000,?,1,1,1,?,?)',
	undef, '00:11:22:33:44:55', 'Legacy Song', 'manual',
);
$legacy->disconnect;

my ($legacy_api_rows) = Plugins::ShazamCapture::History::view_matches(
	File::Spec->catfile('var', 'backups', 'legacy.sqlite3'),
	{
		filter_field => 'api_source',
		filter_value => 'anything',
	},
);
is_deeply(
	$legacy_api_rows,
	[],
	'API filter safely returns no matches for legacy database',
);

my ($legacy_title_rows) = Plugins::ShazamCapture::History::view_matches(
	File::Spec->catfile('var', 'backups', 'legacy.sqlite3'),
	{
		filter_field => 'title',
		filter_value => 'legacy',
	},
);
is(scalar @$legacy_title_rows, 1, 'legacy database remains filterable');

done_testing();
