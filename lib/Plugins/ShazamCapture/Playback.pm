package Plugins::ShazamCapture::Playback;

use strict;
use Slim::Control::Request;
use Slim::Music::Info;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes qw(time);

my $log = logger('plugin.shazamcapture');
my $prefs = preferences('plugin.shazamcapture');
my (%metadata, %candidate);
my $song_changed_error = 'Song changed before recognition completed';

sub init {
	Slim::Control::Request::subscribe(\&_playback_event, [
		['playlist'], ['newsong', 'stop']
	]);
	Slim::Control::Request::subscribe(\&_metadata_event, [['newmetadata']]);
}

sub _playback_event {
	my ($request) = @_;
	my $client = $request->client or return;
	return if Plugins::ShazamCapture::Auto::publishing($client);
	my $id = lc $client->id;
	my $event = $request->isCommand([['playlist'], ['stop']])
		? 'stop' : $song_changed_error;
	Plugins::ShazamCapture::Plugin::cancel_recognition($id, $event);
	Plugins::ShazamCapture::Auto::playback_changed($client, $event);

	# LMS emits newsong only after the new stream has buffered and started. The
	# byte hook may therefore have already created the correct generation and
	# decoder. Do not destroy that fresh decoder (especially for FLAC/Ogg,
	# which cannot be restarted in the middle of the stream).
	if ($event ne 'stop') {
		my $song = eval { $client->streamingSong };
		my $identity = $song ? eval { "$song" } : '';
		my $state = Plugins::ShazamCapture::Capture::state($id);
		if ($state && !$state->{awaiting_stream} && $identity && $state->{identity} eq $identity) {
			$log->info("new-song event for $id already belongs to capture generation $state->{generation}");
			return;
		}
	}

	delete $metadata{$id};
	delete $candidate{$id};
	Slim::Utils::Timers::killTimers($client, \&_metadata_commit);
	my $generation = Plugins::ShazamCapture::Capture::invalidate($id, $event);
	$log->info("capture invalidated for $id generation $generation: $event");
}

sub _metadata_event {
	my ($request) = @_;
	my $client = $request->client or return;
	return if Plugins::ShazamCapture::Auto::publishing($client);
	Plugins::ShazamCapture::Auto::metadata_changed($client);
	return unless $prefs->get('flushOnSameStreamMetadata');
	my $id = lc $client->id;
	my $state = Plugins::ShazamCapture::Capture::state($id) or return;
	return if $state->{awaiting_stream};
	my $identity = $state->{identity} || return;
	my $value = _normalized_metadata($client);
	return unless length $value;

	# The first usable value for each physical stream establishes a baseline.
	if (!exists $metadata{$id} || $metadata{$id}->{identity} ne $identity) {
		$metadata{$id} = { identity => $identity, value => $value };
		delete $candidate{$id};
		return;
	}
	if ($metadata{$id}->{value} eq $value) {
		if (delete $candidate{$id}) {
			Slim::Utils::Timers::killTimers($client, \&_metadata_commit);
			if (Plugins::ShazamCapture::Capture::end_pcm_transition(
				$id, 'metadata transition reverted'
			)) {
				$log->info("PCM collection restarted for $id after metadata reverted");
			}
		}
		return;
	}
	Plugins::ShazamCapture::Capture::begin_pcm_transition(
		$id, 'same-stream metadata transition started'
	);
	$candidate{$id} = { identity => $identity, value => $value };
	Slim::Utils::Timers::killTimers($client, \&_metadata_commit);
	Slim::Utils::Timers::setTimer($client, time() + 2, \&_metadata_commit, $id, $identity, $value);
}

sub _metadata_commit {
	my ($client, $id, $identity, $expected) = @_;
	if (!$prefs->get('flushOnSameStreamMetadata')) {
		delete $candidate{$id};
		Plugins::ShazamCapture::Capture::end_pcm_transition(
			$id, 'same-stream metadata clearing disabled'
		);
		return;
	}
	return unless $client;
	my $state = Plugins::ShazamCapture::Capture::state($id) or return;
	if ($state->{awaiting_stream} || ($state->{identity} || '') ne $identity) {
		delete $candidate{$id};
		return;
	}
	my $pending = $candidate{$id} or return;
	return unless $pending->{identity} eq $identity && $pending->{value} eq $expected;
	my $current = _normalized_metadata($client);
	return unless length($current) && $current eq $expected;
	my $baseline = $metadata{$id} or return;
	return unless $baseline->{identity} eq $identity;
	return if $baseline->{value} eq $current;
	$metadata{$id} = { identity => $identity, value => $current };
	delete $candidate{$id};
	if (Plugins::ShazamCapture::Capture::end_pcm_transition(
		$id, 'stable same-stream metadata change'
	)) {
		$log->info("PCM collection restarted for $id after stable metadata change on the same stream");
	}
	Plugins::ShazamCapture::Plugin::cancel_recognition(
		$id, $song_changed_error, 'manual'
	);
}

sub _normalized_metadata {
	my ($client) = @_;
	my $song = eval { $client->streamingSong };
	my $track = $song && eval { $song->currentTrack };
	my $url = $track && eval { $track->url } || '';
	my $value = eval { Slim::Music::Info::getCurrentTitle($client, $url) } || '';
	$value =~ s/^\s+|\s+$//g;
	$value =~ s/\s+/ /g;
	return lc $value;
}

1;
