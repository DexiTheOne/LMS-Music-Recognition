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

my $log = logger('plugin.shazamcapture');
my $prefs = preferences('plugin.shazamcapture');
my $cache = Slim::Utils::Cache->new();
my (%timers, %overlay, %publishing, %publishing_until);

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
	Plugins::ShazamCapture::Capture::clear_pcm($id, 'automatic recognition cycle started');
	my $generation = $state->{generation};
	my $started = Plugins::ShazamCapture::Plugin::start_recognition(
		$client,
		sub {
			my ($result, $completed_generation) = @_;
			my $current = Plugins::ShazamCapture::Capture::state($id);
			if (
				$result->{ok} && $result->{matched} && !$result->{stale}
				&& $prefs->get('autoMetadataOverlay')
				&& $current && $current->{generation} == $completed_generation
				&& eligible($client)
			) {
				_publish_overlay($client, $current, $result->{track});
			}
			elsif (
				$result->{exhausted_without_valid_match}
				&& $prefs->get('autoClearOverlayOnNoMatch')
				&& !$prefs->get('skipConfirmationsAfterTwoNoMatches')
			) {
				clear_overlay(
					$client,
					'automatic recognition retries exhausted without a valid match'
				);
			}
			return unless eligible($client);
			_schedule($client, _cooldown());
		},
		'auto'
	);
	if (!$started->{ok}) {
		$log->info("automatic recognition could not start for $id: "
			. ($started->{error} || 'unknown error'));
		_schedule($client, 1) if eligible($client);
	}
}

sub _publish_overlay {
	my ($client, $state, $track) = @_;
	return unless $client && $state && ref $track eq 'HASH';
	my $id = lc $client->id;
	my $song = eval { $client->playingSong } || eval { $client->streamingSong };
	return unless $song;
	my $old = eval { $song->pluginData('wmaMeta') };
	$overlay{$id} ||= { song => $song, old => $old };
	$overlay{$id}->{track} = {
		title => $track->{title} || '',
		artist => $track->{artist} || '',
		album => $track->{album} || '',
		artwork_url => $track->{artwork_url} || '',
	};
	my $meta = {
		title => $track->{title}, artist => $track->{artist},
		album => $track->{album}, cover => $track->{artwork_url},
	};
	eval { $song->pluginData(wmaMeta => $meta) };
	for my $url (grep { defined $_ && length $_ } (
		$state->{url}, eval { $song->track->url }, eval { $song->currentTrack->url }
	)) {
		$cache->set("remote_image_$url", $track->{artwork_url}, 86400)
			if $track->{artwork_url};
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
	my $saved = delete $overlay{$id} or return;
	my $song = $saved->{song};
	eval { $song->pluginData(wmaMeta => $saved->{old}) } if $song;
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

sub _cooldown {
	my $value = $prefs->get('autoCooldownSeconds');
	$value = 120 unless defined $value && "$value" =~ /^\d+$/;
	$value = 30 if $value < 30;
	$value = 900 if $value > 900;
	return int($value);
}

1;
