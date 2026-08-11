package Plugins::ShazamCapture::Auto;

use strict;
use Slim::Control::Request;
use Slim::Music::Info;
use Slim::Player::Client;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes qw(time);
use Plugins::ShazamCapture::Artwork;

my $log = logger('plugin.shazamcapture');
my $prefs = preferences('plugin.shazamcapture');
my $cache = Slim::Utils::Cache->new();
my (%timers, %overlay, %publishing, %publishing_until, %menu_status);

sub init {
	settings_changed();
}

sub observe {
	my ($client) = @_;
	return unless $client;
	return unless eligible($client);
	my $id = lc $client->id;
	return if $timers{$id};
	_schedule($client, 0.5);
}

sub settings_changed {
	for my $client (Slim::Player::Client::clients()) {
		next unless $client;
		if (eligible($client)) {
			_schedule($client, 0.1);
		}
		else {
			cancel($client, 'automatic recognition settings changed', 1);
		}
	}
}

sub eligible {
	my ($client) = @_;
	return 0 unless $client && $prefs->get('autoRecognition');
	return 0 unless eval { $client->isPlaying };
	my ($scheme, $station) = _source($client);
	return 0 unless $scheme eq 'radio' || $scheme eq 'hlspl';
	return 0 if _ignored($station);
	return 1;
}

sub active {
	my ($client) = @_;
	return 0 unless eligible($client);
	my $id = lc $client->id;
	return ($timers{$id} || Plugins::ShazamCapture::Plugin::recognition_running($id)) ? 1 : 0;
}

sub publishing {
	my ($client) = @_;
	return 0 unless $client;
	my $id = lc $client->id;
	return 1 if $publishing{$id};
	return ($publishing_until{$id} || 0) > time() ? 1 : 0;
}

sub status {
	my ($client) = @_;
	return {} unless $client;
	my $id = lc $client->id;
	my ($scheme, $station) = _source($client);
	return {
		eligible => eligible($client) ? 1 : 0,
		source_scheme => $scheme,
		station => $station,
		ignored => _ignored($station) ? 1 : 0,
		next_trigger_at => $timers{$id} ? int($timers{$id}->{at}) : 0,
		overlay => $overlay{$id} ? $overlay{$id}->{track} : undef,
	};
}

sub overlay {
	my ($client) = @_;
	return unless $client;
	my $current = $overlay{lc $client->id} or return;
	return unless ref $current->{track} eq 'HASH';
	return { %{$current->{track}} };
}

sub menu_status {
	my ($client) = @_;
	return unless $client;
	return $menu_status{lc $client->id};
}

sub playback_changed {
	my ($client, $reason) = @_;
	return unless $client;
	cancel($client, $reason || 'playback changed', 1);
	_schedule($client, 0.5) if eligible($client);
}

sub metadata_changed {
	my ($client) = @_;
	return unless $client;
	my $id = lc $client->id;
	return if $publishing{$id};
	return unless $prefs->get('flushOnSameStreamMetadata');
	return unless eligible($client);
	Plugins::ShazamCapture::Plugin::cancel_recognition(
		$id, 'native metadata changed during automatic recognition', 'auto'
	);
	Plugins::ShazamCapture::Capture::clear_pcm(
		$id, 'automatic recognition metadata transition'
	);
	_schedule($client, 0.1);
}

sub cancel {
	my ($client, $reason, $clear) = @_;
	return unless $client;
	my $id = lc $client->id;
	delete $menu_status{$id};
	if (my $timer = delete $timers{$id}) {
		Slim::Utils::Timers::killTimers($timer, \&_tick);
	}
	Plugins::ShazamCapture::Plugin::cancel_recognition($id, $reason, 'auto');
	clear_overlay($client, $reason) if $clear;
}

sub _schedule {
	my ($client, $delay) = @_;
	return unless $client;
	my $id = lc $client->id;
	if (my $old = delete $timers{$id}) {
		Slim::Utils::Timers::killTimers($old, \&_tick);
	}
	my $timer = $timers{$id} = {
		id => $id, client => $client, at => time() + ($delay || 0),
	};
	Slim::Utils::Timers::setTimer($timer, $timer->{at}, \&_tick);
}

sub _tick {
	my ($timer) = @_;
	my $client = $timer->{client};
	my $id = $timer->{id};
	delete $timers{$id} if $timers{$id} && $timers{$id} == $timer;
	return cancel($client, 'automatic stream is no longer eligible', 1)
		unless eligible($client);
	return _schedule($client, 1)
		if Plugins::ShazamCapture::Plugin::recognition_running($id);
	my $state = Plugins::ShazamCapture::Capture::state($id);
	return _schedule($client, 0.5)
		unless $state && !$state->{awaiting_stream};

	# Every automatic cycle starts with audio collected after the trigger.
	delete $menu_status{$id};
	Plugins::ShazamCapture::Capture::clear_pcm($id, 'automatic recognition cycle started');
	my $generation = $state->{generation};
	my $started = Plugins::ShazamCapture::Plugin::start_recognition(
		$client,
		sub {
			my ($result, $completed_generation) = @_;
			if ($result->{ok} && $result->{matched} && !$result->{stale}) {
				delete $menu_status{$id};
			}
			elsif ($result->{ok} && !$result->{matched} && !$result->{stale}) {
				$menu_status{$id} = 'PLUGIN_SHAZAMCAPTURE_AUTO_NO_MATCH';
			}
			elsif (!$result->{stale}) {
				$menu_status{$id} = 'PLUGIN_SHAZAMCAPTURE_AUTO_FAILED';
			}
			my $current = Plugins::ShazamCapture::Capture::state($id);
			if (
				$result->{ok} && $result->{matched} && !$result->{stale}
				&& $prefs->get('autoMetadataOverlay')
				&& $current && $current->{generation} == $completed_generation
				&& eligible($client)
			) {
				_prepare_overlay($client, $current, $result->{track});
			}
			elsif (
				$prefs->get('autoClearOverlayOnNoMatch')
				&& !$result->{stale}
				&& !($result->{ok} && $result->{matched})
			) {
				clear_overlay(
					$client,
					'automatic recognition completed without a valid match'
				);
			}
			return unless eligible($client);
			_schedule($client, _cooldown());
		},
		'auto'
	);
	if (!$started->{ok}) {
		$menu_status{$id} = 'PLUGIN_SHAZAMCAPTURE_AUTO_FAILED';
		$log->info("automatic recognition could not start for $id: "
			. ($started->{error} || 'unknown error'));
		_schedule($client, 1) if eligible($client);
	}
}

sub _prepare_overlay {
	my ($client, $state, $track) = @_;
	my $id = lc $client->id;
	my (undef, $station) = _source($client);
	$station = _station_label($station);
	return _publish_overlay($client, $state, $track)
		unless $track->{artwork_url} && $station;
	Plugins::ShazamCapture::Artwork->compose(
		$id, $state->{generation}, $track->{artwork_url}, $station,
		sub {
			my ($ready, $generation) = @_;
			my $current = Plugins::ShazamCapture::Capture::state($id);
			return unless $current
				&& $current->{generation} == $generation
				&& eligible($client);
			my %published = %$track;
			$published{station_artwork_ready} = $ready ? 1 : 0;
			_publish_overlay($client, $current, \%published);
		}
	);
}

sub _publish_overlay {
	my ($client, $state, $track) = @_;
	return unless $client && $state && ref $track eq 'HASH';
	my $id = lc $client->id;
	my $song = eval { $client->playingSong } || eval { $client->streamingSong };
	return unless $song;
	my $old = eval { $song->pluginData('wmaMeta') };
	$old = undef if _plugin_owned_meta($old);
	my @urls = grep { defined $_ && length $_ } (
		$state->{url}, eval { $song->track->url }, eval { $song->currentTrack->url }
	);
	if (!$overlay{$id}) {
		my %old_images = map {
			my $key = "remote_image_$_";
			$key => $cache->get($key)
		} @urls;
		$overlay{$id} = {
			song => $song, old => $old, old_images => \%old_images,
		};
	}
	my $artwork_url = $track->{station_artwork_ready}
		? Plugins::ShazamCapture::Artwork::url($id)
		: undef;
	$artwork_url ||= $track->{artwork_url} || '';
	$overlay{$id}->{track} = {
		title => $track->{title} || '',
		artist => $track->{artist} || '',
		album => $track->{album} || '',
		artwork_url => $artwork_url,
	};
	my $meta = {
		title => $track->{title}, artist => $track->{artist},
		album => $track->{album}, cover => $artwork_url,
	};
	eval { $song->pluginData(wmaMeta => $meta) };
	for my $url (@urls) {
		$cache->set("remote_image_$url", $artwork_url, 86400)
			if $artwork_url;
	}
	$client->metaTitle(join(' - ', grep { defined $_ && length $_ }
		($track->{artist}, $track->{title})));
	$publishing_until{$id} = time() + 2;
	local $publishing{$id} = 1;
	Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
	Slim::Control::Request::notifyFromArray($client, [
		'playlist', 'newsong', $track->{title} || ''
	]);
	$client->update();
	$log->info("automatic metadata overlay published for $id: "
		. join(' — ', grep { defined $_ && length $_ }
			($track->{title}, $track->{artist}, $track->{album})));
}

sub clear_overlay {
	my ($client, $reason) = @_;
	return unless $client;
	my $id = lc $client->id;
	Plugins::ShazamCapture::Artwork::clear($id);
	my $saved = delete $overlay{$id} or return;
	my $song = $saved->{song};
	eval { $song->pluginData(wmaMeta => $saved->{old}) } if $song;
	for my $key (keys %{$saved->{old_images} || {}}) {
		my $old = $saved->{old_images}->{$key};
		defined $old
			? $cache->set($key, $old, 86400)
			: $cache->remove($key);
	}
	$client->metaTitle('');
	$publishing_until{$id} = time() + 2;
	local $publishing{$id} = 1;
	Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
	Slim::Control::Request::notifyFromArray($client, [
		'playlist', 'newsong', ''
	]);
	$client->update();
	$log->info("automatic metadata overlay cleared for $id: "
		. ($reason || 'overlay cleared'));
}

sub _plugin_owned_meta {
	my ($meta) = @_;
	return 0 unless ref $meta eq 'HASH';
	my $cover = $meta->{cover} || '';
	return $cover =~ m{/plugins/ShazamCapture/artwork/}i ? 1 : 0;
}

sub _source {
	my ($client) = @_;
	my $song = eval { $client->streamingSong } || eval { $client->playingSong };
	my $track = $song && eval { $song->track };
	my $current = $song && eval { $song->currentTrack };
	my $url = ($track && eval { $track->url }) || '';
	my $station = ($track && eval { $track->title }) || '';
	$station ||= ($current && eval { $current->title }) || '';
	my ($scheme) = $url =~ m{^([a-z][a-z0-9+.-]*):}i;
	$scheme = lc($scheme || '');

	# Plain HTTP(S) playlist entries are LMS radio streams. Plugin-owned
	# schemes (Spotty, podcasts, etc.) remain excluded even when their resolved
	# current track is HTTP.
	$scheme = 'radio' if $scheme eq 'http' || $scheme eq 'https';
	return ($scheme, $station);
}

sub _ignored {
	my ($station) = @_;
	my $needle = _normalize($station);
	return 0 unless length $needle;
	for my $entry (split /,/, ($prefs->get('autoIgnoredStations') || '')) {
		return 1 if _normalize($entry) eq $needle;
	}
	return 0;
}

sub _normalize {
	my ($value) = @_;
	$value = lc($value || '');
	$value =~ s/^\s+|\s+$//g;
	$value =~ s/\s+/ /g;
	return $value;
}

sub _station_label {
	my ($station) = @_;
	$station = '' unless defined $station;
	$station =~ s/^\s+|\s+$//g;
	$station =~ s/\s+/ /g;
	return '' unless length $station;
	if ($station =~ m{^[a-z][a-z0-9+.-]*://([^/:?#]+)}i) {
		my $host = lc $1;
		$host =~ s/^www\.//;
		return "Radio - $host";
	}
	return $station;
}

sub _cooldown {
	my $value = $prefs->get('autoCooldownSeconds');
	$value = 120 unless defined $value && "$value" =~ /^\d+$/;
	$value = 30 if $value < 30;
	$value = 900 if $value > 900;
	return int($value);
}

1;
