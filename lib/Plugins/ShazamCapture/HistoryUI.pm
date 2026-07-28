package Plugins::ShazamCapture::HistoryUI;

use strict;

use Plugins::ShazamCapture::History;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.shazamcapture');
$prefs->init({
	showSpotifyInHistory  => 1,
	historyThisPlayerOnly => 0,
	historyFilterField    => 'none',
	historyFilterValue    => '',
	historySortOrder      => 'newest',
});

sub feed {
	return sub {
		my ($client, $callback) = @_;
		my $client_prefs = $client ? $prefs->client($client) : $prefs;
		my $this_player = $client
			&& $client_prefs->get('historyThisPlayerOnly');
		my $filter_field = $client_prefs->get('historyFilterField') || 'none';
		my $filter_value = $client_prefs->get('historyFilterValue') || '';
		my $sort_order = $client_prefs->get('historySortOrder') || 'newest';
		my $rows = Plugins::ShazamCapture::History::all_matches({
			player_id    => $this_player ? $client->id : undef,
			filter_field => $filter_field,
			filter_value => $filter_value,
			sort_order   => $sort_order,
		});
		my $subtitle = _subtitle(
			$client, $this_player, $filter_field, $filter_value, $sort_order
		);
		my @items = (
			{
				name => $subtitle,
				type => 'textarea',
			},
			map { _history_item($_) } @$rows,
		);
		$callback->({
			title => 'Shazam History',
			items => \@items,
		});
	};
}

sub _subtitle {
	my ($client, $this_player, $filter_field, $filter_value, $sort_order) = @_;
	my $scope = 'All players';
	if ($this_player && $client) {
		$scope = eval { $client->name } || eval { $client->id } || 'Selected player';
	}
	$scope = _plain_text($scope);
	$filter_value = _plain_text($filter_value);

	my %filter_labels = (
		station => 'Station',
		source  => 'Stream source',
		artist  => 'Artist',
		title   => 'Song title',
		album   => 'Album',
		capture => 'Capture type',
	);
	my $filter = 'No filter';
	if ($filter_labels{$filter_field || ''} && length $filter_value) {
		$filter = qq{$filter_labels{$filter_field} contains "$filter_value"};
	}

	my %sort_labels = (
		newest      => 'Newest to Oldest',
		oldest      => 'Oldest to Newest',
		artist_asc  => 'Artist A-Z',
		artist_desc => 'Artist Z-A',
		title_asc   => 'Song Title A-Z',
		title_desc  => 'Song Title Z-A',
	);
	my $sort = $sort_labels{$sort_order || ''} || $sort_labels{newest};
	return join(' - ', $scope, $filter, $sort);
}

sub _plain_text {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/[\x00-\x1f\x7f]+/ /g;
	$value =~ s/[<>]//g;
	$value =~ s/\s+/ /g;
	$value =~ s/^\s+|\s+$//g;
	return $value;
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
