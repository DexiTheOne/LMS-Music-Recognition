package Plugins::ShazamCapture::UI;

use strict;
use Slim::Control::Request;
use Slim::Menu::TrackInfo;
use Slim::Utils::Log qw(logger);
use Slim::Utils::Timers;

my $log = logger('plugin.shazamcapture');

sub init {
	Slim::Menu::TrackInfo->registerInfoProvider( shazamCapture => (
		before => 'top',
		func   => \&track_info_item,
	) );
	Slim::Control::Request::addDispatch(
		['shazamcaptureui', 'recognize'],
		[1, 0, 1, \&_recognize_command]
	);
	Slim::Control::Request::addDispatch(
		['shazamcaptureui', 'items', '_index', '_quantity'],
		[1, 1, 1, \&_recognize_command]
	);
}

sub track_info_item {
	my ($client, undef, undef, undef, $tags) = @_;
	return unless $client;
	if (Plugins::ShazamCapture::Auto::eligible($client)) {
		return [{
			name => $client->string('PLUGIN_SHAZAMCAPTURE_AUTO_ON'),
			type => 'text',
			isContextMenu => 1,
		}];
	}

	# XMLBrowser's later callback arguments contain the feed's own query, not
	# the TrackInfo request which created this item. Capture menuMode here,
	# while TrackInfo still exposes the initiating control's request context.
	my $menu_mode = $tags && ($tags->{menuMode} || '');
	my $is_material = length($menu_mode) && $menu_mode ne '1';
	# Both Material and Jive request their More menu with menu=1. Material
	# executes actions over JSON-RPC, while Jive executes them through Comet.
	# Defer that ambiguous mode until the direct command retains its source.
	my $origin = $is_material ? 'material' : 'auto';

	return [{
		name => $client->string('PLUGIN_SHAZAMCAPTURE_RECOGNIZE'),
		jive => {
			actions => {
				go => {
					player     => 0,
					cmd        => ['shazamcaptureui', 'items'],
					params     => { origin => $origin },
					nextWindow => 'parentNoRefresh',
				},
			},
		},
		itemActions => {
			allAvailableActionsDefined => 1,
			items => {
				command => ['shazamcaptureui', 'items'],
				fixedParams => {
					origin => $origin,
				},
			},
		},
		url  => sub {
			my ($action_client, $cb, $params) = @_;
			my $is_button = $params && $params->{isButton};
			my $started = Plugins::ShazamCapture::Plugin::start_recognition(
				$action_client,
				sub {
					my ($result) = @_;
					_complete_action(
						$action_client, $cb, $result,
						$is_button, !$is_button && $is_material
					);
				}
			);

			_complete_action(
				$action_client, $cb, $started,
				$is_button, !$is_button && $is_material
			) unless $started->{ok};
		},
		nextWindow => 'parent',
	}];
}

sub _recognize_command {
	my ($request) = @_;
	my $client = $request->client;
	my $origin = $request->getParam('origin') || 'material';
	if ($origin eq 'auto') {
		$origin = ($request->source || '') eq 'JSONRPC' ? 'material' : 'jive';
	}
	else {
		$origin = $origin eq 'jive' ? 'jive' : 'material';
	}
	$log->info(
		'UI recognize command origin=' . $origin .
		' source=' . ($request->source || '<none>') .
		' connection=' . ($request->connectionID || '<none>')
	);
	$request->setStatusProcessing();

	my $started = Plugins::ShazamCapture::Plugin::start_recognition(
		$client,
		sub {
			my ($result) = @_;
			_complete_command($request, $client, $origin, $result);
		}
	);

	_complete_command($request, $client, $origin, $started)
		unless $started->{ok};
}

sub _complete_command {
	my ($request, $client, $origin, $result) = @_;
	my $message = _result_message($client, $result);

	if ($origin eq 'material') {
		# Material keeps fetchingItem active while this list-shaped request is
		# pending, then displays the sole text row through its native result
		# popup. The response is scoped to the browser which initiated it.
		$request->addResultLoop('item_loop', 0, 'text', $message);
		$request->addResultLoop('item_loop', 0, 'type', 'text');
		$request->setStatusDone();
		return;
	}

	$request->setStatusDone();
	$client->showBriefly({
		jive => {
			type     => 'popupplay',
			text     => [$message],
			duration => 10000,
		},
	}, {
		duration => 10,
		name     => 'shazamcapture',
	});
}

sub _complete_action {
	my ($client, $cb, $result, $is_button, $is_material) = @_;
	my $message = _result_message($client, $result);

	if ($is_material) {
		# Do not publish a player display popup: that can leak into Jive UIs
		# observing the same player. Material receives its scoped notification
		# after the pending action response has settled.
		$cb->({ items => [] });
		Slim::Utils::Timers::setTimer(
			$client, time() + 0.1, \&_notify_material_result, $result
		);
		return;
	}

	$cb->({
		items => [{
			name        => $message,
			showBriefly => 1,
			nowPlaying  => 1,
		}]
	});

	if ($is_button) {
		Slim::Utils::Timers::setTimer(
			$client, time() + 0.1, \&_show_sb2_result, $result
		);
	}
}

sub _result_message {
	my ($client, $result) = @_;
	if (
		$result->{ok} && $result->{matched} &&
		$result->{track} && ref $result->{track} eq 'HASH'
	) {
		return join(' — ', grep { defined $_ && length $_ } @{$result->{track}}{qw(title artist album)});
	}
	return $client->string('PLUGIN_SHAZAMCAPTURE_NO_MATCH')
		if $result->{ok} && !$result->{matched};
	return $client->string('PLUGIN_SHAZAMCAPTURE_ERROR')
		. ': ' . ($result->{error} || 'Unknown error');
}

sub _notify_material_result {
	my ($client, $result) = @_;
	my $type = $result->{ok} ? 'info' : 'error';
	_notify_material($client, $type, _result_message($client, $result));
}

sub _show_sb2_result {
	my ($client, $result) = @_;
	my @lines;
	if (
		$result->{ok} && $result->{matched} &&
		$result->{track} && ref $result->{track} eq 'HASH'
	) {
		@lines = (
			$result->{track}->{artist} || '',
			$result->{track}->{title} || '',
		);
	}
	else {
		@lines = (
			$client->string('PLUGIN_SHAZAMCAPTURE'),
			_result_message($client, $result),
		);
	}
	$client->showBriefly({
		line => \@lines,
		fonts => {
			'graphic-320x32' => 'standard',
		},
	}, {
		duration => 10,
		name     => 'shazamcapture',
	});
}

sub _notify_material {
	my ($client, $type, $message, $seconds) = @_;
	my @command = (
		'material-skin', 'send-notif',
		'type:' . $type,
		'msg:' . $message,
		'client:' . $client->id,
	);
	push @command, 'timeout:' . $seconds if defined $seconds;
	Slim::Control::Request::executeRequest(undef, \@command);
}

1;
