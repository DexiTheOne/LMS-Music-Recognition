package Plugins::ShazamCapture::UI;

use strict;
use Slim::Control::Request;
use Slim::Menu::TrackInfo;
use Slim::Utils::Timers;

sub init {
	Slim::Menu::TrackInfo->registerInfoProvider( shazamCapture => (
		before => 'top',
		func   => \&track_info_item,
	) );
}

sub track_info_item {
	my ($client) = @_;
	return unless $client;
	if (Plugins::ShazamCapture::Auto::eligible($client)) {
		return [{
			name => $client->string('PLUGIN_SHAZAMCAPTURE_AUTO_ON'),
			type => 'text',
			isContextMenu => 1,
		}];
	}

	return [{
		name => $client->string('PLUGIN_SHAZAMCAPTURE_RECOGNIZE'),
		url  => sub {
			my ($action_client, $cb) = @_;
			my $progress = $action_client->string('PLUGIN_SHAZAMCAPTURE_IN_PROGRESS');
			my $started = Plugins::ShazamCapture::Plugin::start_recognition(
				$action_client,
				sub {
					my ($result) = @_;
					_popup_result($action_client, $result);
				}
			);
			my $message = $started->{ok}
				? $progress
				: _result_message($action_client, $started);

			$cb->({
				items => [{
					name        => $message,
					showBriefly => 1,
					nowPlaying  => 1,
				}]
			});

			if ($started->{ok}) {
				my $duration =
					Plugins::ShazamCapture::Plugin::recognition_timeout_seconds() + 5;
				Slim::Utils::Timers::setTimer(
					$action_client, time() + 0.1, \&_show_progress,
					lc($action_client->id), $progress, $duration
				);
			}
		},
		nextWindow => 'parent',
	}];
}

sub _show_progress {
	my ($client, $id, $progress, $duration) = @_;
	return unless Plugins::ShazamCapture::Plugin::recognition_running($id);
	_popup($client, 'info', [$progress], $duration);
}

sub _popup_result {
	my ($client, $result) = @_;
	if (!$result->{ok}) {
		return _popup($client, 'error', [_result_message($client, $result)], 10);
	}
	if (!$result->{matched} || !$result->{track} || ref $result->{track} ne 'HASH') {
		return _popup($client, 'info', [$client->string('PLUGIN_SHAZAMCAPTURE_NO_MATCH')], 8);
	}

	my $track = $result->{track};
	my @lines = grep { defined $_ && length $_ } (
		$track->{title},
		$track->{artist},
		$track->{album},
	);
	_popup($client, 'info', \@lines, 10);
}

sub _result_message {
	my ($client, $result) = @_;
	return $client->string('PLUGIN_SHAZAMCAPTURE_NO_MATCH')
		if $result->{ok} && !$result->{matched};
	return $client->string('PLUGIN_SHAZAMCAPTURE_ERROR')
		. ': ' . ($result->{error} || 'Unknown error');
}

sub _popup {
	my ($client, $type, $lines, $seconds, $notify_material) = @_;
	return unless $client;
	$lines = [$lines] unless ref $lines eq 'ARRAY';
	$notify_material = 1 unless defined $notify_material;

	$client->showBriefly({
		line => $lines,
		jive => {
			type     => 'popupplay',
			text     => $lines,
			duration => $seconds * 1000,
		},
	}, {
		duration => $seconds,
		name     => 'shazamcapture',
	});

	if ($notify_material) {
		# Use Material Skin's supported command rather than publishing its
		# internal topic ourselves. The command validates and emits the exact
		# notification shape expected by active Material browser sessions.
		Slim::Control::Request::executeRequest(undef, [
			'material-skin', 'send-notif',
			'type:' . $type,
			# Material's snackbar is single-line and discards text following a
			# newline. Preserve Jive's multi-line array, but flatten Material.
			'msg:' . join(' — ', @$lines),
			'client:' . $client->id,
			'timeout:' . $seconds,
		]);
	}
}

1;
