package Plugins::ShazamCapture::HistoryUI;

use strict;

use Plugins::ShazamCapture::History;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.shazamcapture');
$prefs->init({ showSpotifyInHistory => 1 });

sub feed {
	return sub {
		my ($client, $callback) = @_;
		my $rows = Plugins::ShazamCapture::History::all_matches();
		my @items = map { _history_item($_) } @$rows;
		$callback->({
			title => 'Shazam History',
			items => \@items,
		});
	};
}

sub _history_item {
	my ($row) = @_;
	my @details;
	_detail(\@details, 'Song', $row->{title});
	_detail(\@details, 'Artist', $row->{artist});
	_detail(\@details, 'Album', $row->{album});
	_detail(\@details, 'Radio station', $row->{source_name});
	_detail(\@details, 'Technical source', $row->{technical_source});
	_detail(\@details, 'Player', $row->{player_name} || $row->{player_id});
	_detail(\@details, 'Recognized', $row->{recognized_at_local});
	_detail(\@details, 'Sample type',
		($row->{trigger_method} || 'manual') eq 'auto' ? 'Auto Sample' : 'Manual Sample');
	_detail_link(\@details, 'Apple Music', $row->{apple_music_url});
	if ($prefs->get('showSpotifyInHistory')) {
		if ($row->{spotify_url}) {
			_detail_link(\@details, 'Spotify', $row->{spotify_url});
		}
		else {
			_detail(\@details, 'Spotify', 'No Spotify Link Returned');
		}
	}
	_detail_link(\@details, 'Shazam', $row->{shazam_url});

	return {
		name  => $row->{title},
		type  => 'link',
		image => $row->{artwork_url} || 'html/images/cover.png',
		items => \@details,
	};
}

sub _detail {
	my ($items, $label, $value) = @_;
	return unless defined $value && length $value;
	push @$items, {
		name => "$label: $value",
		type => 'text',
	};
}

sub _detail_link {
	my ($items, $label, $url) = @_;
	return unless defined $url && length $url;
	push @$items, {
		name    => "$label: $url",
		type    => 'text',
		weblink => $url,
	};
}

1;
