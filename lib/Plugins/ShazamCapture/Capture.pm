package Plugins::ShazamCapture::Capture;

use strict;
use Time::HiRes qw(time);

my %state;
my $limit = 4 * 1024 * 1024;
my $pending_limit = 512 * 1024;
my $pcm_limit = 30 * 16000 * 2;
# Large enough for common FLAC/Ogg initialization blocks, but short enough not
# to materially contaminate a later recognition sample with old programme audio.
my $prefix_limit = 64 * 1024;

sub set_limit {
	my ($bytes) = @_;
	$limit = $bytes if $bytes && $bytes >= 65536 && $bytes <= 32 * 1024 * 1024;
}

sub _id { lc($_[0]->id) }

sub observe {
	my ($client, $bytes) = @_;
	return unless $client && defined $bytes && length $bytes;
	my $decoder_bytes = $bytes;
	my $song = eval { $client->streamingSong };
	return unless $song;
	my $url = eval { $song->currentTrack->url } || '';
	return unless $url =~ m{^[a-z][a-z0-9+.-]*://}i && $url !~ m{^file://}i;

	my $id = _id($client);
	my $identity = eval { "$song" } || $url;
	my $s = $state{$id};
	if (!$s || $s->{identity} ne $identity) {
		my $generation = !$s ? 1 : ($s->{awaiting_stream} ? $s->{generation} : $s->{generation} + 1);
		$s = $state{$id} = {
			generation => $generation,
			pcm_epoch => 1,
			identity => $identity, url => $url, buffer => '', prefix => '',
			pending => '', pcm => '', pcm_total => 0, dropped => 0,
			total => 0, started => time(), last_seen => 0,
		};
	}
	$s->{last_seen} = time();
	$s->{total} += length($bytes);
	if (length($s->{prefix}) < $prefix_limit) {
		my $needed = $prefix_limit - length($s->{prefix});
		my $take = length($bytes) < $needed ? length($bytes) : $needed;
		$s->{prefix} .= substr($bytes, 0, $take);
		$bytes = substr($bytes, $take);
	}
	$s->{buffer} .= $bytes;
	my $payload_limit = $limit - length($s->{prefix});
	substr($s->{buffer}, 0, length($s->{buffer}) - $payload_limit, '')
		if length($s->{buffer}) > $payload_limit;
	$s->{format} = eval { $song->streamformat } || '';

	# This queue is consumed only by an LMS timer. Never wait for FFmpeg in the
	# player write path; discard new decoder input if its bounded queue is full.
	my $space = $pending_limit - length($s->{pending});
	if ($space > 0) {
		$s->{pending} .= substr($decoder_bytes, 0, $space);
	}
	$s->{dropped} += length($decoder_bytes) - $space
		if length($decoder_bytes) > $space;
	eval { Plugins::ShazamCapture::Decoder::notify($id) };
}

sub state { $state{lc($_[0])} }
sub invalidate {
	my ($id, $reason) = @_;
	$id = lc $id;
	my $old = $state{$id};
	my $generation = $old ? $old->{generation} + 1 : 1;
	$state{$id} = {
		generation => $generation, pcm_epoch => 1, identity => '', url => '',
		buffer => '', prefix => '', pending => '', pcm => '',
		pcm_total => 0, dropped => 0, total => 0,
		started => time(), last_seen => 0, awaiting_stream => 1,
		invalidation_reason => $reason || '',
	};
	eval { Plugins::ShazamCapture::Decoder::invalidate($id, $reason || 'playback invalidated') };
	return $generation;
}
sub clear_pcm {
	my ($id, $reason) = @_;
	my $s = $state{lc $id} or return 0;
	$s->{pcm} = '';
	$s->{pcm_total} = 0;
	$s->{pcm_epoch} = ($s->{pcm_epoch} || 1) + 1;
	$s->{pcm_cleared_at} = time();
	$s->{pcm_clear_reason} = $reason || '';
	return 1;
}
sub begin_pcm_transition {
	my ($id, $reason) = @_;
	my $s = $state{lc $id} or return 0;
	if (!$s->{pcm_transition}) {
		clear_pcm($id, $reason || 'metadata transition started');
		$s->{pcm_transition} = 1;
		$s->{pcm_transition_started_at} = time();
	}
	return 1;
}
sub end_pcm_transition {
	my ($id, $reason) = @_;
	my $s = $state{lc $id} or return 0;
	return 0 unless delete $s->{pcm_transition};
	clear_pcm($id, $reason || 'metadata transition completed');
	delete $s->{pcm_transition_started_at};
	return 1;
}
sub reset {
	my ($id) = @_;
	my $s = $state{lc $id} or return;
	$s->{buffer} = ''; $s->{pcm} = ''; $s->{total} = 0;
	$s->{pcm_total} = 0; $s->{started} = time();
	$s->{pcm_epoch} = ($s->{pcm_epoch} || 1) + 1;
}
sub snapshot {
	my ($id) = @_;
	my $s = state($id) or return;
	my $buffer = $s->{buffer};
	my $prefix = $s->{prefix} || '';
	return ($prefix . $buffer, $s->{generation});
}
sub take_pending {
	my ($id, $generation, $max) = @_;
	my $s = state($id) or return '';
	return '' unless $s->{generation} == $generation;
	my $take = length($s->{pending}) < $max ? length($s->{pending}) : $max;
	return '' unless $take;
	return substr($s->{pending}, 0, $take, '');
}
sub append_pcm {
	my ($id, $generation, $bytes) = @_;
	my $s = state($id) or return;
	return unless $s->{generation} == $generation && defined $bytes && length $bytes;
	return if $s->{pcm_transition};
	$s->{pcm} .= $bytes;
	$s->{pcm_total} += length($bytes);
	substr($s->{pcm}, 0, length($s->{pcm}) - $pcm_limit, '')
		if length($s->{pcm}) > $pcm_limit;
}
sub snapshot_pcm {
	my ($id, $seconds) = @_;
	my $s = state($id) or return;
	$seconds = 20 unless defined $seconds;
	$seconds = 5 if $seconds < 5;
	$seconds = 30 if $seconds > 30;
	my $recognition_bytes = $seconds * 16000 * 2;
	my $pcm = $s->{pcm_transition} ? '' : length($s->{pcm}) > $recognition_bytes
		? substr($s->{pcm}, -$recognition_bytes)
		: $s->{pcm};
	return ($pcm, $s->{generation}, $s->{pcm_epoch} || 1, $s->{pcm_total} || 0);
}
sub mode {
	my ($id, $client) = @_;
	my $s = state($id);
	return 'proxied' if $s && time() - $s->{last_seen} < 5;
	return 'direct' if $client && eval { $client->isPlaying } && (!$s || time() - $s->{last_seen} > 15);
	return 'unknown';
}

1;
