package Plugins::ShazamCapture::UI;

use strict;
use Slim::Control::Request;
use Slim::Menu::TrackInfo;
use Slim::Utils::Log qw(logger);
use Slim::Utils::Timers;

my $log = logger('plugin.shazamcapture');
my $request_execute_original;
my $set_result_loop_hash_original;
our $active_request;

sub init {
	Slim::Menu::TrackInfo->registerInfoProvider( shazamCapture => (
		before => 'top',
		func   => \&track_info_item,
	) );
	# SqueezePlay can retain Request objects whose TrackInfo function pointer
	# was resolved before plugin initialization. Every such object still goes
	# through Request::execute, so retain the active request only for that
	# synchronous execution. The provider can then classify its transport
	# without changing or replacing the cached TrackInfo handler.
	unless ($request_execute_original) {
		$request_execute_original = \&Slim::Control::Request::execute;
		no warnings 'redefine';
		*Slim::Control::Request::execute = \&_execute_with_request;
		$log->info('installed request-context wrapper for TrackInfo transport');
	}
	# TrackInfo feeds can outlive the request which built them. Apply the final
	# navigation metadata while XMLBrowser serializes the row for a concrete
	# connection, where the control UI's transport is authoritative.
	unless ($set_result_loop_hash_original) {
		$set_result_loop_hash_original
			= \&Slim::Control::Request::setResultLoopHash;
		no warnings 'redefine';
		*Slim::Control::Request::setResultLoopHash
			= \&_set_result_loop_hash_for_transport;
		$log->info('installed result-row transport wrapper for UI navigation');
	}
	Slim::Control::Request::addDispatch(
		['shazamcaptureui', 'recognize'],
		[1, 0, 1, \&_recognize_command]
	);
	Slim::Control::Request::addDispatch(
		['shazamcaptureui', 'items', '_index', '_quantity'],
		[1, 1, 1, \&_recognize_command]
	);
}

sub _execute_with_request {
	my $want = wantarray;
	local $active_request = $_[0];
	if (!defined $want) {
		$request_execute_original->(@_);
		return;
	}
	if ($want) {
		return $request_execute_original->(@_);
	}
	return scalar $request_execute_original->(@_);
}

sub _set_result_loop_hash_for_transport {
	my ($request, $loop, $index, $row) = @_;
	if (
		ref $row eq 'HASH'
		&& ref $row->{actions} eq 'HASH'
		&& ref $row->{actions}->{go} eq 'HASH'
		&& _is_recognition_items_command($row->{actions}->{go}->{cmd})
	) {
		my $action = $row->{actions}->{go};
		my $origin = _transport_origin($request->source);
		if ($origin) {
			$action->{params} ||= {};
			$action->{params}->{origin} = $origin;
			if ($origin eq 'jive') {
				delete $action->{nextWindow};
				delete $row->{nextWindow};
			}
			else {
				$action->{nextWindow} = 'parentNoRefresh';
			}
			$log->info(
				'serialized UI row origin=' . $origin .
				' source=' . ($request->source || '<none>') .
				' nextWindow=' . ($action->{nextWindow} || '<child>')
			);
		}
	}
	return $set_result_loop_hash_original->(@_);
}

sub _is_recognition_items_command {
	my ($command) = @_;
	return ref $command eq 'ARRAY'
		&& @$command == 2
		&& $command->[0] eq 'shazamcaptureui'
		&& $command->[1] eq 'items';
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
	# The request-context wrapper makes that transport available while this provider
	# builds the row. Fall back to the menu hint for nonstandard callers.
	my $request_origin = $active_request
		? _transport_origin($active_request->source)
		: undef;
	# A source-less request is not proof of Material. SqueezePlay can rebuild
	# TrackInfo through an internal request with menu=track and no transport.
	# Keep those rows neutral so neither UI receives destructive navigation.
	my $origin = $request_origin || 'auto';
	my $go_action = {
		player => 0,
		cmd    => ['shazamcaptureui', 'items'],
		params => { origin => $origin },
	};
	# Material must not pre-push a browse layer. Jive deliberately receives no
	# nextWindow: it locks this menu while the request is pending, then pushes
	# the terminal result as a child window with a normal Back action.
	$go_action->{nextWindow} = 'parentNoRefresh'
		if $origin eq 'material';
	$log->info(
		'UI TrackInfo row origin=' . $origin .
		' transport=' . ($request_origin || '<none>') .
		' menu=' . (length($menu_mode) ? $menu_mode : '<none>') .
		' nextWindow=' . ($go_action->{nextWindow} || '<child>')
	);

	my $item = {
		name => $client->string('PLUGIN_SHAZAMCAPTURE_RECOGNIZE'),
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
	};
	# Traditional XMLBrowser must follow the URL callback so it supplies
	# isButton and receives the native showBriefly result. A source-less
	# control-UI row still needs the neutral direct action: SqueezePlay can
	# cache and select that row after a transport-specific refresh. Traditional
	# rows have no menuMode and therefore keep only the URL callback.
	if ($origin ne 'auto' || length($menu_mode)) {
		$item->{jive} = {
			actions => {
				go => $go_action,
			},
		};
		$item->{itemActions} = {
			allAvailableActionsDefined => 1,
			items => {
				command => ['shazamcaptureui', 'items'],
				fixedParams => {
					origin => $origin,
				},
			},
		};
	}
	# Traditional-button clients need to return to their parent after the URL
	# callback. Do not expose that fallback to Jive: SqueezePlay applies the
	# item's top-level nextWindow when its go action omits one, which would
	# close the More menu before the pending child request can show its wheel.
	$item->{nextWindow} = 'parent'
		if !length($menu_mode);
	return [$item];
}

sub _recognize_command {
	my ($request) = @_;
	my $client = $request->client;
	my $origin = _request_origin(
		$request, $request->getParam('origin') || 'material'
	);
	$log->info(
		'UI recognize command origin=' . $origin .
		' source=' . ($request->source || '<none>') .
		' connection=' . ($request->connectionID || '<none>')
	);
	$request->setStatusProcessing();
	my $guard = { completed => 0 };
	my $ui_timeout = eval {
		Plugins::ShazamCapture::Plugin::recognition_timeout_seconds()
	} || 120;
	Slim::Utils::Timers::setTimer(
		$guard, time() + $ui_timeout + 5,
		\&_recognize_command_timed_out, $request, $client, $origin
	);

	my $started = eval {
		Plugins::ShazamCapture::Plugin::start_recognition(
			$client,
			sub {
				my ($result) = @_;
				_complete_command(
					$request, $client, $origin, $result, $guard
				);
			}
		);
	};
	if (!$started || ref $started ne 'HASH') {
		my $error = $@ || 'Recognition could not be started';
		$error =~ s/\s+$//;
		$started = {
			ok => 0, stage => 'ui', error => $error
		};
	}

	_complete_command($request, $client, $origin, $started, $guard)
		unless $started->{ok};
}

sub _request_origin {
	my ($request, $hint) = @_;
	my $origin = _transport_origin($request->source);
	return $origin if $origin;
	return 'button' if $hint eq 'auto';
	return $hint eq 'jive' ? 'jive' : 'material';
}

sub _transport_origin {
	my ($source) = @_;
	$source ||= '';
	return 'material' if $source eq 'JSONRPC';
	return 'jive'
		if $source =~ /SqueezePlay/i
		|| $source =~ m{(?:^|/)slim/request(?:\||$)}i;
	return;
}

sub _recognize_command_timed_out {
	my ($guard, $request, $client, $origin) = @_;
	return if $guard->{completed};
	_complete_command($request, $client, $origin, {
		ok => 0, stage => 'ui', error => 'Recognition UI timed out'
	}, $guard);
	Plugins::ShazamCapture::Plugin::cancel_recognition(
		$client->id, 'Recognition UI timed out', 'manual'
	) if $client;
}

sub _complete_command {
	my ($request, $client, $origin, $result, $guard) = @_;
	return if $guard && $guard->{completed};
	if ($guard) {
		$guard->{completed} = 1;
		Slim::Utils::Timers::killTimers(
			$guard, \&_recognize_command_timed_out
		);
	}
	my $message = _result_message($client, $result);

	if ($origin eq 'button') {
		# Cached traditional rows may still invoke the direct command once.
		# Complete it with the shape XMLBrowser expects, then show the native
		# two-line result after its loading screen has unwound.
		$request->addResult('items', []);
		$request->setStatusDone();
		Slim::Utils::Timers::setTimer(
			$client, time() + 0.1, \&_show_sb2_result, $result
		);
		return;
	}

	if ($origin eq 'material') {
		# Material keeps fetchingItem active while this list-shaped request is
		# pending, then displays the sole text row through its native result
		# popup. Mark the response row as navigational so Material does not
		# decorate a sole non-clickable text row with an HTML div before passing
		# its title to the escaped snackbar. The clicked item's nextWindow still
		# controls the actual navigation. The response remains scoped to the
		# browser which initiated it.
		$request->addResultLoop('item_loop', 0, 'text', $message);
		$request->addResultLoop('item_loop', 0, 'type', 'text');
		$request->addResultLoop(
			'item_loop', 0, 'nextWindow', 'parentNoRefresh'
		);
		$request->setStatusDone();
		return;
	}

	# Jive intentionally loads this response into the child window it prepared
	# when the action began. Completing the request removes the inline wheel;
	# the user returns through the child's normal Back action.
	$request->addResult('offset', 0);
	$request->addResult('count', 1);
	$request->addResultLoop('item_loop', 0, 'text', $message);
	$request->addResultLoop('item_loop', 0, 'style', 'itemNoAction');
	$request->addResultLoop('item_loop', 0, 'action', 'none');
	$request->setStatusDone();
}

sub _complete_action {
	my ($client, $cb, $result, $is_button, $is_material) = @_;
	my $message = _result_message($client, $result);

	if ($is_button) {
		$cb->({
			items => [{
				name        => $message,
				showBriefly => 1,
				nowPlaying  => 1,
			}]
		});
		Slim::Utils::Timers::setTimer(
			$client, time() + 0.1, \&_show_sb2_result, $result
		);
		return;
	}

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
}

sub _result_message {
	my ($client, $result) = @_;
	if (
		$result->{ok} && $result->{matched} &&
		$result->{track} && ref $result->{track} eq 'HASH'
	) {
		my @fields = map { _plain_text($_) }
			@{$result->{track}}{qw(title artist album)};
		return join(' - ', grep { length $_ } @fields);
	}
	return _plain_text($client->string('PLUGIN_SHAZAMCAPTURE_NO_MATCH'))
		if $result->{ok} && !$result->{matched};
	return _plain_text(
		$client->string('PLUGIN_SHAZAMCAPTURE_ERROR')
		. ': ' . ($result->{error} || 'Unknown error')
	);
}

sub _plain_text {
	my ($value) = @_;
	return '' unless defined $value;

	my $text = "$value";
	# Material renders result rows in an escaped snackbar. Remove markup here
	# so HTML-bearing metadata cannot appear as literal tags in that popup.
	$text =~ s/&#x([0-9a-f]+);/_entity_chr(hex($1))/gei;
	$text =~ s/&#([0-9]+);/_entity_chr($1)/ge;
	$text =~ s/&nbsp;/ /gi;
	$text =~ s/&amp;/&/gi;
	$text =~ s/&quot;/"/gi;
	$text =~ s/&#39;/'/gi;
	$text =~ s/&lt;/</gi;
	$text =~ s/&gt;/>/gi;
	$text =~ s{<(?:br|hr)\b[^>]*>} { }gi;
	$text =~ s{</(?:div|p|h[1-6]|li|tr|td|th)\s*>} { }gi;
	$text =~ s{<[^>]*>}{}g;
	$text =~ s/[\x00-\x1f\x7f]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

sub _entity_chr {
	my ($codepoint) = @_;
	return '' unless defined $codepoint
		&& $codepoint > 0
		&& $codepoint <= 0x10ffff
		&& !($codepoint >= 0xd800 && $codepoint <= 0xdfff);
	return chr($codepoint);
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
