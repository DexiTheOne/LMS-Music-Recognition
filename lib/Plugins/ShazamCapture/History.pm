package Plugins::ShazamCapture::History;

use strict;
use DBI;
use JSON::XS;
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
	my ($player_id, $generation, $result, $context, $trigger_method) = @_;
	die 'recognition history is not initialized' unless $dbh;
	$result ||= {};
	return unless $result->{ok} && $result->{matched};
	my $track = ref $result->{track} eq 'HASH' ? $result->{track} : {};
	return unless defined $track->{title} && length $track->{title};
	$context ||= {};
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
		. 'technical_source,apple_music_url,spotify_url,artwork_url,shazam_url,trigger_method) '
		. 'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
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
		. 'technical_source,apple_music_url,spotify_url,artwork_url,shazam_url,trigger_method FROM recognition_history '
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
	return [] unless $dbh;
	my $rows = $dbh->selectall_arrayref(
		'SELECT id,recognized_at,player_id,generation,title,artist,album,shazam_key,'
		. 'player_name,source_name,source_url,technical_source,apple_music_url,'
		. 'spotify_url,artwork_url,shazam_url,trigger_method '
		. 'FROM recognition_history WHERE ok=1 AND matched=1 '
		. 'ORDER BY recognized_at DESC,id DESC',
		{ Slice => {} },
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

sub path {
	return $path || '';
}

1;
