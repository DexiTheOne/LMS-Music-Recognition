package Plugins::ShazamCapture::History;

use strict;
use DBI;
use DBD::SQLite ();
use JSON::XS;
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);

my $dbh;
my $path;
my $root;

sub init {
	my ($plugin_root, $filename) = @_;
	$root = $plugin_root;
	return select_database($filename || 'history.sqlite3', 1);
}

sub _valid_filename {
	my ($filename) = @_;
	return unless defined $filename;
	return $filename
		if $filename =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\.sqlite3\z/
			&& basename($filename) eq $filename;
	return;
}

sub _database_path {
	my ($filename) = @_;
	die 'recognition history is not initialized' unless $root;
	$filename = _valid_filename($filename)
		or die 'Database filename must end in .sqlite3 and contain only letters, numbers, dots, dashes, or underscores';
	return File::Spec->catfile($root, 'var', $filename);
}

sub _connect {
	my ($database_path) = @_;
	my $handle = DBI->connect(
		"dbi:SQLite:dbname=$database_path", '', '',
		{
			RaiseError     => 1,
			PrintError     => 0,
			AutoCommit     => 1,
			sqlite_unicode => 1,
		}
	);
	$handle->do('PRAGMA journal_mode = WAL');
	$handle->do('PRAGMA synchronous = NORMAL');
	return $handle;
}

sub _initialize_schema {
	$dbh->do(<<'SQL');
CREATE TABLE IF NOT EXISTS recognition_history (
	id            INTEGER PRIMARY KEY AUTOINCREMENT,
	recognized_at INTEGER NOT NULL,
	player_id     TEXT NOT NULL,
	generation    INTEGER NOT NULL,
	ok            INTEGER NOT NULL,
	matched       INTEGER NOT NULL,
	stale         INTEGER NOT NULL,
	title         TEXT,
	artist        TEXT,
	album         TEXT,
	shazam_key    TEXT,
	stage         TEXT,
	error         TEXT,
	result_json   TEXT NOT NULL
)
SQL
	$dbh->do(
		'CREATE INDEX IF NOT EXISTS recognition_history_time '
		. 'ON recognition_history(recognized_at DESC, id DESC)'
	);
	_add_column('player_name', 'TEXT');
	_add_column('source_name', 'TEXT');
	_add_column('source_url', 'TEXT');
	_add_column('technical_source', 'TEXT');
	_add_column('apple_music_url', 'TEXT');
	_add_column('spotify_url', 'TEXT');
	_add_column('artwork_url', 'TEXT');
	_add_column('shazam_url', 'TEXT');
	_add_column('trigger_method', 'TEXT');
	_add_column('api_source', 'TEXT');
	_add_column('api_reason', 'TEXT');
	$dbh->do("UPDATE recognition_history SET trigger_method='manual' "
		. "WHERE trigger_method IS NULL OR trigger_method=''");
	_clean_stored_apple_urls();
	_clean_stored_spotify_urls();
}

sub select_database {
	my ($filename, $create) = @_;
	my $new_path = _database_path($filename);
	die "Database file does not exist: $filename" unless $create || -f $new_path;
	my $new_dbh = _connect($new_path);
	my $old_dbh = $dbh;
	$dbh = $new_dbh;
	eval { _initialize_schema() };
	if ($@) {
		my $error = $@;
		eval { $new_dbh->disconnect };
		$dbh = $old_dbh;
		die $error;
	}
	$path = $new_path;
	eval { $old_dbh->disconnect } if $old_dbh;
	return 1;
}

sub databases {
	return [] unless $root;
	my $var = File::Spec->catdir($root, 'var');
	opendir my $dir, $var or return [];
	my @files = sort grep {
		_valid_filename($_) && -f File::Spec->catfile($var, $_)
	} readdir $dir;
	closedir $dir;
	return \@files;
}

sub active_database {
	return $path ? basename($path) : 'history.sqlite3';
}

sub backup {
	die 'recognition history is not initialized' unless $dbh && $path && $root;
	my $directory = File::Spec->catdir($root, 'var', 'backups');
	make_path($directory);
	my $stem = active_database();
	$stem =~ s/\.sqlite3\z//;
	my $timestamp = strftime('%Y%m%d-%H%M%S', localtime());
	my $filename = "$stem-$timestamp.sqlite3";
	my $backup_path = File::Spec->catfile($directory, $filename);
	my $suffix = 1;
	while (-e $backup_path) {
		$filename = "$stem-$timestamp-$suffix.sqlite3";
		$backup_path = File::Spec->catfile($directory, $filename);
		$suffix++;
	}
	eval {
		$dbh->sqlite_backup_to_file($backup_path);
		my $verify = DBI->connect(
			"dbi:SQLite:dbname=$backup_path", '', '',
			{ RaiseError => 1, PrintError => 0 }
		);
		$verify->do('PRAGMA journal_mode = DELETE');
		my ($integrity) = $verify->selectrow_array('PRAGMA integrity_check');
		$verify->disconnect;
		die 'Backup verification failed'
			unless defined $integrity && $integrity eq 'ok';
	};
	if ($@) {
		my $error = $@;
		unlink $_ for $backup_path, "$backup_path-wal", "$backup_path-shm";
		die $error;
	}
	return $backup_path;
}

sub backup_and_clear {
	my $backup_path = backup();
	$dbh->begin_work;
	eval {
		$dbh->do('DELETE FROM recognition_history');
		$dbh->do("DELETE FROM sqlite_sequence WHERE name='recognition_history'");
		$dbh->commit;
	};
	if ($@) {
		my $error = $@;
		eval { $dbh->rollback };
		die $error;
	}
	$dbh->do('PRAGMA wal_checkpoint(TRUNCATE)');
	$dbh->do('VACUUM');
	return $backup_path;
}

sub _add_column {
	my ($name, $type) = @_;
	my $columns = $dbh->selectall_arrayref('PRAGMA table_info(recognition_history)', { Slice => {} });
	return if grep { $_->{name} eq $name } @$columns;
	$dbh->do("ALTER TABLE recognition_history ADD COLUMN $name $type");
}

sub _clean_url {
	my ($url) = @_;
	return $url unless defined $url && length $url;
	$url =~ s{^[a-z][a-z0-9+.-]*://music\.apple\.com}{https://music.apple.com}i;
	$url =~ s{^//music\.apple\.com}{https://music.apple.com}i;
	$url =~ s/[?#].*$//;
	return $url;
}

sub _clean_stored_apple_urls {
	my $rows = $dbh->selectall_arrayref(
		'SELECT id,apple_music_url,result_json FROM recognition_history '
		. 'WHERE apple_music_url IS NOT NULL AND apple_music_url != ?',
		{ Slice => {} }, '',
	);
	my $update = $dbh->prepare(
		'UPDATE recognition_history SET apple_music_url=?,result_json=? WHERE id=?'
	);
	for my $row (@$rows) {
		my $clean = _clean_url($row->{apple_music_url});
		my $result = eval { JSON::XS->new->utf8->decode($row->{result_json}) };
		if ($result && ref $result->{track} eq 'HASH') {
			$result->{track}->{apple_music_url} = $clean;
			$row->{result_json} = JSON::XS->new->canonical->utf8->encode($result);
		}
		$update->execute($clean, $row->{result_json}, $row->{id});
	}
}

sub _clean_spotify_url {
	my ($url) = @_;
	return undef unless defined $url && length $url;
	if ($url =~ m{^spotify:track:([^?#]+)}i || $url =~ m{^spotify://track/([^?#]+)}i) {
		return "https://open.spotify.com/track/$1";
	}
	return undef unless $url =~ m{^(?:[a-z][a-z0-9+.-]*:)?//open\.spotify\.com(/[^?#]*)}i;
	return "https://open.spotify.com$1";
}

sub _clean_stored_spotify_urls {
	my $rows = $dbh->selectall_arrayref(
		'SELECT id,spotify_url,result_json FROM recognition_history '
		. 'WHERE spotify_url IS NOT NULL AND spotify_url != ?',
		{ Slice => {} }, '',
	);
	my $update = $dbh->prepare(
		'UPDATE recognition_history SET spotify_url=?,result_json=? WHERE id=?'
	);
	for my $row (@$rows) {
		my $clean = _clean_spotify_url($row->{spotify_url});
		my $result = eval { JSON::XS->new->utf8->decode($row->{result_json}) };
		if ($result && ref $result->{track} eq 'HASH') {
			$result->{track}->{spotify_url} = $clean;
			$row->{result_json} = JSON::XS->new->canonical->utf8->encode($result);
		}
		$update->execute($clean, $row->{result_json}, $row->{id});
	}
}

sub record {
	my ($player_id, $generation, $result, $context, $trigger_method, $provenance) = @_;
	die 'recognition history is not initialized' unless $dbh;
	$result ||= {};
	return unless $result->{ok} && $result->{matched};
	my $track = ref $result->{track} eq 'HASH' ? $result->{track} : {};
	return unless defined $track->{title} && length $track->{title};
	$context ||= {};
	$provenance ||= {};
	my $recognized_at = int($context->{recognized_at} || time());
	my $last = $dbh->selectrow_hashref(
		'SELECT recognized_at,title,artist,album,shazam_key FROM recognition_history '
		. 'WHERE player_id=? AND ok=1 AND matched=1 ORDER BY recognized_at DESC,id DESC LIMIT 1',
		undef, $player_id,
	);
	if ($last && $recognized_at - $last->{recognized_at} <= 600
		&& _same_track($last, $track)) {
		return;
	}
	my $json = JSON::XS->new->canonical->utf8->encode($result);
	$dbh->do(
		'INSERT INTO recognition_history '
		. '(recognized_at,player_id,generation,ok,matched,stale,title,artist,album,'
		. 'shazam_key,stage,error,result_json,player_name,source_name,source_url,'
		. 'technical_source,apple_music_url,spotify_url,artwork_url,shazam_url,'
		. 'trigger_method,api_source,api_reason) '
		. 'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
		undef,
		$recognized_at, $player_id, int($generation || 0),
		$result->{ok} ? 1 : 0,
		$result->{matched} ? 1 : 0,
		$result->{stale} ? 1 : 0,
		$track->{title}, $track->{artist}, $track->{album}, $track->{shazam_key},
		$result->{stage}, $result->{error}, $json,
		$context->{player_name}, $context->{source_name}, $context->{source_url},
		$context->{technical_source},
		_clean_url($track->{apple_music_url}), _clean_spotify_url($track->{spotify_url}),
		$track->{artwork_url}, $track->{shazam_url},
		($trigger_method || '') eq 'auto' ? 'auto' : 'manual',
		$provenance->{api_source}, $provenance->{api_reason},
	);
	return $dbh->sqlite_last_insert_rowid();
}

sub _same_track {
	my ($left, $right) = @_;
	if ($left->{shazam_key} && $right->{shazam_key}) {
		return "$left->{shazam_key}" eq "$right->{shazam_key}";
	}
	for my $field (qw(title artist album)) {
		my $a = lc($left->{$field} // '');
		my $b = lc($right->{$field} // '');
		$a =~ s/\s+/ /g; $a =~ s/^\s+|\s+$//g;
		$b =~ s/\s+/ /g; $b =~ s/^\s+|\s+$//g;
		return 0 unless $a eq $b;
	}
	return 1;
}

sub recent {
	my ($limit, $offset) = @_;
	return [] unless $dbh;
	$limit = int($limit || 100);
	$limit = 1 if $limit < 1;
	$limit = 500 if $limit > 500;
	$offset = int($offset || 0);
	$offset = 0 if $offset < 0;
	my $rows = $dbh->selectall_arrayref(
		'SELECT id,recognized_at,player_id,generation,ok,matched,stale,title,artist,'
		. 'album,shazam_key,stage,error,player_name,source_name,source_url,'
		. 'technical_source,apple_music_url,spotify_url,artwork_url,shazam_url,'
		. 'trigger_method,api_source,api_reason FROM recognition_history '
		. 'WHERE ok=1 AND matched=1 '
		. 'ORDER BY recognized_at DESC,id DESC LIMIT ? OFFSET ?',
		{ Slice => {} }, $limit, $offset,
	);
	for my $row (@$rows) {
		$row->{recognized_at_iso} = strftime(
			'%Y-%m-%dT%H:%M:%SZ', gmtime($row->{recognized_at})
		);
	}
	return $rows;
}

sub count {
	return 0 unless $dbh;
	return $dbh->selectrow_array(
		'SELECT COUNT(*) FROM recognition_history WHERE ok=1 AND matched=1'
	) || 0;
}

sub all_matches {
	my ($options) = @_;
	return [] unless $dbh;
	return _all_matches_from_handle($dbh, $options);
}

sub view_matches {
	my ($relative_path, $options) = @_;
	die 'recognition history is not initialized' unless $root;
	my ($view_path, $display_path) = _view_database_path($relative_path);
	my $view_dbh = eval {
		DBI->connect(
			"dbi:SQLite:dbname=$view_path", '', '',
			{
				RaiseError        => 1,
				PrintError        => 0,
				AutoCommit        => 1,
				ReadOnly          => 1,
				sqlite_open_flags => DBD::SQLite::OPEN_READONLY(),
				sqlite_unicode    => 1,
			}
		);
	};
	die 'Selected database could not be opened read-only' unless $view_dbh;
	my $rows = eval {
		my $columns = $view_dbh->selectall_arrayref(
			'PRAGMA table_info(recognition_history)', { Slice => {} }
		);
		my %columns = map { $_->{name} => 1 } @$columns;
		for my $required (qw(
			id recognized_at player_id generation ok matched title artist album shazam_key
			player_name source_name source_url technical_source apple_music_url
			spotify_url artwork_url shazam_url trigger_method
		)) {
			die 'Selected database does not contain a compatible recognition history'
				unless $columns{$required};
		}
		_all_matches_from_handle($view_dbh, $options);
	};
	my $error = $@;
	eval { $view_dbh->disconnect };
	if ($error) {
		die 'Selected database does not contain a compatible recognition history'
			if $error =~ /^Selected database does not contain/;
		die 'Selected database could not be read as recognition history';
	}
	return ($rows, $display_path);
}

sub _view_database_path {
	my ($relative_path) = @_;
	$relative_path = '' unless defined $relative_path;
	$relative_path =~ s/^\s+|\s+$//g;
	die 'Enter or select a plugin-contained .sqlite3 database path'
		unless length $relative_path && $relative_path =~ /\.sqlite3\z/i;
	return _confined_path($relative_path, 1);
}

sub normalize_view_database_path {
	my ($database_path) = @_;
	my (undef, $display_path) = _view_database_path($database_path);
	return $display_path;
}

sub view_database_picker_path {
	my ($database_path) = @_;
	$database_path = File::Spec->catfile('var', 'backups', '')
		unless defined $database_path && length $database_path;
	my ($picker_path) = eval { _confined_path($database_path, 0) };
	return $picker_path;
}

sub _confined_path {
	my ($database_path, $file_only) = @_;
	die 'recognition history is not initialized' unless $root;
	$database_path = '' unless defined $database_path;
	$database_path =~ s/^\s+|\s+$//g;
	die 'Enter a database path' unless length $database_path;
	my $candidate;
	if (File::Spec->file_name_is_absolute($database_path)) {
		$candidate = $database_path;
	}
	else {
		my @parts = File::Spec->splitdir($database_path);
		pop @parts while @parts && !length $parts[-1];
		die 'Database path must stay inside the plugin directory'
			if !@parts || grep { !length($_) || $_ eq '.' || $_ eq '..' } @parts;
		$candidate = File::Spec->catfile($root, @parts);
	}
	die "Database file does not exist: $database_path"
		unless $file_only ? -f $candidate : -e $candidate;
	my $real_root = abs_path($root);
	my $real_candidate = abs_path($candidate);
	die 'Database path could not be resolved'
		unless defined $real_root && defined $real_candidate;
	my $prefix = File::Spec->catfile($real_root, '');
	my ($compare_candidate, $compare_prefix) = ($real_candidate, $prefix);
	if (File::Spec->case_tolerant) {
		$compare_candidate = lc $compare_candidate;
		$compare_prefix = lc $compare_prefix;
	}
	die 'Database path must stay inside the plugin directory'
		unless index($compare_candidate, $compare_prefix) == 0;
	my $display_path = File::Spec->abs2rel($real_candidate, $real_root);
	return ($real_candidate, $display_path);
}

sub _all_matches_from_handle {
	my ($handle, $options) = @_;
	$options ||= {};

	my @where = ('ok=1', 'matched=1');
	my @bind;
	if ($options->{player_id}) {
		push @where, 'player_id=?';
		push @bind, $options->{player_id};
	}

	my %filter_columns = (
		station => 'source_name',
		source  => 'technical_source',
		artist  => 'artist',
		title   => 'title',
		album   => 'album',
		capture => 'trigger_method',
	);
	my $filter_column = $filter_columns{$options->{filter_field} || ''};
	my $filter_value = $options->{filter_value};
	if ($filter_column && defined $filter_value && length $filter_value) {
		$filter_value = lc $filter_value;
		$filter_value =~ s/!/!!/g;
		$filter_value =~ s/%/!%/g;
		$filter_value =~ s/_/!_/g;
		push @where,
			"LOWER(COALESCE($filter_column,'')) LIKE ? ESCAPE '!'";
		push @bind, "%$filter_value%";
	}

	my %sort_orders = (
		newest     => 'recognized_at DESC,id DESC',
		oldest     => 'recognized_at ASC,id ASC',
		artist_asc => "LOWER(COALESCE(artist,'')) ASC,recognized_at DESC,id DESC",
		artist_desc => "LOWER(COALESCE(artist,'')) DESC,recognized_at DESC,id DESC",
		title_asc  => "LOWER(COALESCE(title,'')) ASC,recognized_at DESC,id DESC",
		title_desc => "LOWER(COALESCE(title,'')) DESC,recognized_at DESC,id DESC",
	);
	my $order = $sort_orders{$options->{sort_order} || 'newest'}
		|| $sort_orders{newest};
	my $rows = $handle->selectall_arrayref(
		'SELECT id,recognized_at,player_id,generation,title,artist,album,shazam_key,'
		. 'player_name,source_name,source_url,technical_source,apple_music_url,'
		. 'spotify_url,artwork_url,shazam_url,trigger_method,'
		. _optional_column($handle, 'api_source') . ','
		. _optional_column($handle, 'api_reason') . ' '
		. 'FROM recognition_history WHERE ' . join(' AND ', @where)
		. " ORDER BY $order",
		{ Slice => {} },
		@bind,
	);
	for my $row (@$rows) {
		$row->{recognized_at_iso} = strftime(
			'%Y-%m-%dT%H:%M:%SZ', gmtime($row->{recognized_at})
		);
		$row->{recognized_at_local} = strftime(
			'%Y-%m-%d %H:%M:%S', localtime($row->{recognized_at})
		);
	}
	return $rows;
}

sub _optional_column {
	my ($handle, $name) = @_;
	my $columns = $handle->selectall_arrayref(
		'PRAGMA table_info(recognition_history)', { Slice => {} }
	);
	return $name if grep { $_->{name} eq $name } @$columns;
	return "NULL AS $name";
}

sub path {
	return $path || '';
}

1;
