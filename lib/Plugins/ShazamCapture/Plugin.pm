package Plugins::ShazamCapture::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::XS;
use Slim::Control::Request;
use Slim::Music::Info;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::ShazamCapture::Capture;
use Plugins::ShazamCapture::Decoder;
use Plugins::ShazamCapture::History;
use Plugins::ShazamCapture::HistoryUI;
use Plugins::ShazamCapture::Hook;
use Plugins::ShazamCapture::Playback;
use Plugins::ShazamCapture::Auto;
use Plugins::ShazamCapture::UI;
use Plugins::ShazamCapture::Worker;

if (main::WEBUI) {
	require Plugins::ShazamCapture::Settings;
	require Plugins::ShazamCapture::PlayerSettings;
}

my $log = Slim::Utils::Log->addLogCategory({
	category => 'plugin.shazamcapture', defaultLevel => 'INFO',
	description => 'PLUGIN_SHAZAMCAPTURE',
});
my $root;
my $allow_dump = 0;
my $prefs = preferences('plugin.shazamcapture');
my %recognitions;
my %last_auto_identity;

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(
		feed   => Plugins::ShazamCapture::HistoryUI::feed(),
		tag    => 'shazamhistory',
		weight => 75,
		is_app => 1,
	);
	if (main::WEBUI) {
		Plugins::ShazamCapture::Settings->new;
		Plugins::ShazamCapture::PlayerSettings->new;
	}
	$root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), qw(.. .. ..)));
	make_path(File::Spec->catdir($root, 'var', $_)) for qw(tmp dumps logs);
	Plugins::ShazamCapture::Decoder::init($root);
	$prefs->init({
		saveDebugWav => 0,
		flushOnSameStreamMetadata => 0,
		manualSampleMode => 'buffered',
		sampleSeconds => 10,
		retryCount => 1,
		consecutiveConfirmations => 1,
		skipConfirmationsAfterTwoNoMatches => 0,
		retrySampleSeconds => 10,
		retryDelaySeconds => 5,
		autoRecognition => 0,
		autoMetadataOverlay => 0,
		autoIgnoredStations => '',
		autoCooldownSeconds => 120,
		historyDatabase => 'history.sqlite3',
	});
	my $history_database = $prefs->get('historyDatabase') || 'history.sqlite3';
	eval {
		Plugins::ShazamCapture::History::init(
			$root, $history_database
		)
	};
	if ($@) {
		my $error = $@;
		$log->error("recognition history database $history_database unavailable: $error");
		eval {
			Plugins::ShazamCapture::History::init($root, 'history.sqlite3');
			$prefs->set('historyDatabase', 'history.sqlite3');
		};
		$log->error("default recognition history unavailable: $@") if $@;
	}
	eval { Plugins::ShazamCapture::Hook::install() };
	$log->error("hook unavailable: $@") if $@;
	Slim::Control::Request::addDispatch(['shazamcapture','_cmd'], [1, 0, 1, \&command]);
	Plugins::ShazamCapture::Playback::init();
	Plugins::ShazamCapture::Auto::init();
	Plugins::ShazamCapture::UI::init();
	$log->info("Shazam Capture initialized on LMS $::VERSION");
}

sub _client {
	my ($request) = @_;
	return $request->client;
}
sub _reply {
	my ($request, $data) = @_;
	for my $k (keys %$data) {
		my $v = $data->{$k};
		$v = JSON::XS->new->canonical->encode($v) if ref $v;
		$request->addResult($k, defined $v ? "$v" : '');
	}
	$request->setStatusDone();
}
sub command {
	my ($request) = @_;
	my $client = _client($request);
	return _reply($request, {ok=>0,error=>'A player must be selected'}) unless $client;
	my $id = lc $client->id;
	my $cmd = $request->getParam('_cmd') || 'status';
	my $mode = Plugins::ShazamCapture::Capture::mode($id, $client);
	my $s = Plugins::ShazamCapture::Capture::state($id);

	if ($cmd eq 'status') {
		return _reply($request, {
			ok=>1, enabled=>1, playback_mode=>$mode,
			capturing=>($mode eq 'proxied' ? 1:0), hook_installed=>Plugins::ShazamCapture::Hook::installed(),
			generation=>($s ? $s->{generation}:0),
			bytes_buffered=>($s ? length($s->{prefix} || '') + length($s->{buffer}):0),
			initialization_bytes=>($s ? length($s->{prefix} || ''):0),
			pcm_bytes_buffered=>($s ? length($s->{pcm} || ''):0),
			pcm_seconds=>($s ? sprintf('%.2f', length($s->{pcm} || '') / 32000):0),
			pcm_transition=>($s && $s->{pcm_transition} ? 1:0),
			decoder_input_dropped=>($s ? $s->{dropped}:0),
			decoder_status=>Plugins::ShazamCapture::Decoder::status($id),
			total_bytes_seen=>($s ? $s->{total}:0), format=>($s ? $s->{format}:''),
			song_url=>($s ? _redact($s->{url}):''), worker_running=>recognition_running($id),
			last_result=>Plugins::ShazamCapture::Worker::last($id),
			history_entries=>Plugins::ShazamCapture::History::count(),
			manual_sample_mode=>_manual_sample_mode(),
			auto=>Plugins::ShazamCapture::Auto::status($client),
		});
	}
	if ($cmd eq 'history') {
		my $limit = $request->getParam('limit') || 100;
		my $offset = $request->getParam('offset') || 0;
		return _reply($request, {
			ok=>1,
			total=>Plugins::ShazamCapture::History::count(),
			history=>Plugins::ShazamCapture::History::recent($limit, $offset),
		});
	}
	if ($cmd eq 'reset') {
		Plugins::ShazamCapture::Capture::reset($id);
		return _reply($request, {ok=>1});
	}
	return _reply($request, _mode_error($mode)) unless $mode eq 'proxied';
	if ($cmd eq 'recognize') {
		my $result = start_recognition($client);
		return _reply($request, $result);
	}
	my ($encoded, $generation) = Plugins::ShazamCapture::Capture::snapshot($id);
	my $safe = $id; $safe =~ s/[^a-z0-9]+/_/g;
	return _reply($request, {ok=>0,stage=>'dump',error=>'Encoded dumps are disabled'})
		if $cmd eq 'dump' && !$allow_dump;
	my $path = File::Spec->catfile(
		$root, 'var', 'dumps',
		sprintf('%s_%d_%d.bin', $safe, $generation, int(rand(1e9)))
	);
	open my $fh, '>', $path or return _reply($request,{ok=>0,error=>"Cannot create plugin-local snapshot: $!"});
	binmode $fh; print {$fh} $encoded; close $fh;
	return _reply($request,{ok=>1,path=>$path,bytes=>length($encoded),generation=>$generation})
		if $cmd eq 'dump';
	unlink $path;
	return _reply($request,{ok=>0,error=>'Unknown command'});
}

sub start_recognition {
	my ($client, $done, $trigger_method) = @_;
	$trigger_method = ($trigger_method || '') eq 'auto' ? 'auto' : 'manual';
	return {ok=>0,error=>'A player must be selected'} unless $client;
	my $id = lc $client->id;
	return {ok=>0,stage=>'automatic',error=>'Automatic recognition owns this radio stream'}
		if $trigger_method eq 'manual' && Plugins::ShazamCapture::Auto::eligible($client);
	return {ok=>0,stage=>'worker',error=>'Recognition is already running'}
		if recognition_running($id);
	my $mode = Plugins::ShazamCapture::Capture::mode($id, $client);
	return _mode_error($mode) unless $mode eq 'proxied';
	my $sample_seconds = _pref_int('sampleSeconds', 5, 30, 10);
	if ((_manual_sample_mode()) eq 'fresh') {
		return _start_sample_wait($client, $done, $sample_seconds, 1, $trigger_method);
	}
	my ($bytes, $generation, $pcm_epoch, $pcm_total) =
		Plugins::ShazamCapture::Capture::snapshot_pcm($id, $sample_seconds);
	if (length($bytes || '') < $sample_seconds * 32000) {
		return _start_sample_wait($client, $done, $sample_seconds, 0, $trigger_method);
	}
	my $safe = $id; $safe =~ s/[^a-z0-9]+/_/g;
	my $path = File::Spec->catfile($root,'var','tmp',sprintf('%s_%d_%d.s16le',$safe,$generation,int(rand(1e9))));
	open my $fh, '>', $path or return {ok=>0,error=>"Cannot create plugin-local snapshot: $!"};
	binmode $fh; print {$fh} $bytes; close $fh;
	my $started = _start_worker(
		$id, $generation, $path, $done,
		_history_context($client, Plugins::ShazamCapture::Capture::state($id)),
		$pcm_epoch, $pcm_total, $sample_seconds, $trigger_method
	);
	unlink $path unless $started;
	return $started
		? {ok=>1,started=>1,generation=>$generation}
		: {ok=>0,stage=>'worker',error=>'Recognition is already running or worker could not start'};
}

sub _start_sample_wait {
	my ($client, $done, $sample_seconds, $clear, $trigger_method) = @_;
	my $id = lc $client->id;
	Plugins::ShazamCapture::Capture::clear_pcm($id, 'fresh manual identification')
		if $clear;
	my (undef, $generation, $pcm_epoch, $pcm_total) =
		Plugins::ShazamCapture::Capture::snapshot_pcm($id, $sample_seconds);
	return {ok=>0,stage=>'capture',error=>'No active PCM capture is available'}
		unless defined $generation;
	my $session = $recognitions{$id} = _new_session(
		$id, $generation, $done,
		_history_context($client, Plugins::ShazamCapture::Capture::state($id)),
		$pcm_epoch, $pcm_total, $trigger_method
	);
	$session->{sample_waiting} = 1;
	$session->{initial_sample_seconds} = $sample_seconds;
	$log->info(sprintf(
		'%s %s identification waiting for %d seconds of PCM for %s',
		$clear ? 'fresh' : 'buffered', $trigger_method || 'manual',
		$sample_seconds, $id
	));
	Slim::Utils::Timers::setTimer(
		$session, time() + 0.1, \&_sample_ready, $id
	);
	return {ok=>1,started=>1,generation=>$generation};
}

sub _sample_ready {
	my ($session, $id) = @_;
	return unless $recognitions{$id} && $recognitions{$id} == $session;
	my ($bytes, $generation, $pcm_epoch, $pcm_total) =
		Plugins::ShazamCapture::Capture::snapshot_pcm(
			$id, $session->{initial_sample_seconds}
		);
	if (!defined $generation || $generation != $session->{generation}) {
		return _finish_recognition($session, {
			ok=>JSON::XS::false, stale=>JSON::XS::true, stage=>'capture',
			error=>'Playback changed while collecting the fresh sample'
		});
	}

	# A configured metadata clear (or manual reset) starts the freshness window
	# again without touching FFmpeg or creating a competing capture path.
	if (($pcm_epoch || 1) != $session->{pcm_epoch}) {
		$session->{pcm_epoch} = $pcm_epoch || 1;
		$session->{pcm_total} = $pcm_total || 0;
	}
	my $needed = $session->{initial_sample_seconds} * 32000;
	if (length($bytes || '') < $needed) {
		Slim::Utils::Timers::setTimer(
			$session, time() + 0.1, \&_sample_ready, $id
		);
		return;
	}
	$session->{sample_waiting} = 0;
	$session->{pcm_total} = $pcm_total || 0;
	my $path = _write_pcm_snapshot($id, $generation, $bytes, 'sample1');
	return _finish_recognition($session, {
		ok=>JSON::XS::false, stage=>'capture',
		error=>'Cannot create plugin-local PCM snapshot'
	}) unless $path;
	my $started = _launch_attempt(
		$session, $path, $session->{initial_sample_seconds}
	);
	if (!$started) {
		unlink $path;
		_finish_recognition($session, {
			ok=>JSON::XS::false, stage=>'worker',
			error=>'Recognition worker could not start'
		});
	}
}

sub _start_worker {
	my ($id, $generation, $path, $done, $context, $pcm_epoch, $pcm_total, $sample_seconds, $trigger_method) = @_;
	$id = lc $id;
	return 0 if recognition_running($id);
	my $session = $recognitions{$id} = _new_session(
		$id, $generation, $done, $context, $pcm_epoch, $pcm_total, $trigger_method
	);
	my $started = _launch_attempt($session, $path, $sample_seconds);
	if (!$started) {
		Slim::Utils::Timers::killTimers($session, \&_recognition_timed_out);
		delete $recognitions{$id};
	}
	return $started;
}

sub _new_session {
	my ($id, $generation, $done, $context, $pcm_epoch, $pcm_total, $trigger_method) = @_;
	my $session = {
		id => $id,
		generation => $generation,
		pcm_epoch => $pcm_epoch || 1,
		pcm_total => $pcm_total || 0,
		done => $done,
		context => $context,
		trigger_method => ($trigger_method || '') eq 'auto' ? 'auto' : 'manual',
		sample_mode => _manual_sample_mode(),
		attempt => 1,
		retries => _pref_int('retryCount', 0, 10, 1),
		confirmations_required => _pref_int('consecutiveConfirmations', 1, 11, 1),
		confirmations => 0,
		leading_no_matches => 0,
		skip_confirmations_after_two_no_matches =>
			$prefs->get('skipConfirmationsAfterTwoNoMatches') ? 1 : 0,
		retry_sample_seconds => _pref_int('retrySampleSeconds', 5, 30, 10),
		retry_delay_seconds => _pref_int('retryDelaySeconds', 1, 30, 5),
	};
	Slim::Utils::Timers::setTimer(
		$session, time() + recognition_timeout_seconds(),
		\&_recognition_timed_out, $id
	);
	return $session;
}

sub recognition_timeout_seconds {
	my $initial_sample = _pref_int('sampleSeconds', 5, 30, 10);
	my $retries = _pref_int('retryCount', 0, 10, 1);
	my $retry_sample = _pref_int('retrySampleSeconds', 5, 30, 10);
	my $retry_delay = _pref_int('retryDelaySeconds', 1, 30, 5);
	my $attempts = $retries + 1;

	# Each worker has a 20-second operation timeout and a five-second
	# supervisor cushion. Sampling terms bound waits when PCM stops arriving.
	return $initial_sample + 5
		+ ($attempts * 25)
		+ ($retries * ($retry_delay + $retry_sample));
}

sub _recognition_timed_out {
	my ($session, $id) = @_;
	return unless $recognitions{$id} && $recognitions{$id} == $session;
	Plugins::ShazamCapture::Worker->cancel($id);
	_finish_recognition($session, {
		ok=>JSON::XS::false, stage=>'recognition',
		error=>'Recognition timed out'
	});
}

sub _launch_attempt {
	my ($session, $path, $sample_seconds) = @_;
	my $id = $session->{id};
	return Plugins::ShazamCapture::Worker->start(
		$id, $session->{generation}, $path, $root, 20, $sample_seconds,
		$prefs->get('saveDebugWav') ? 1 : 0, sub {
		my ($result,$gen) = @_;
		my $now = Plugins::ShazamCapture::Capture::state($id);
		$result->{stale} = (
			!$now || $now->{generation} != $gen ||
			($now->{pcm_epoch} || 1) != $session->{pcm_epoch}
		) ? JSON::XS::true : JSON::XS::false;
		if ($result->{ok} && !$result->{stale}) {
			$session->{last_result} = $result;
			if ($result->{matched}) {
				my $identity = _result_identity($result);
				if (
					$session->{trigger_method} eq 'auto'
					&& $session->{attempt} == 1
					&& defined $identity
					&& defined $last_auto_identity{$id}
					&& $identity eq $last_auto_identity{$id}
				) {
					$session->{confirmations} = $session->{confirmations_required};
					$result->{repeat_of_previous_auto} = JSON::XS::true;
					$result->{confirmations} = $session->{confirmations};
					$result->{confirmations_required} = $session->{confirmations_required};
					return _finish_recognition($session, $result);
				}
				if (
					defined $identity && defined $session->{confirmation_identity} &&
					$identity eq $session->{confirmation_identity}
				) {
					$session->{confirmations}++;
				}
				else {
					$session->{confirmation_identity} = $identity;
					$session->{confirmations} = 1;
				}
				if ($session->{confirmations} >= $session->{confirmations_required}) {
					$result->{confirmations} = $session->{confirmations};
					$result->{confirmations_required} = $session->{confirmations_required};
					return _finish_recognition($session, $result);
				}
			}
			else {
				$session->{confirmation_identity} = undef;
				$session->{confirmations} = 0;
				if (
					$session->{attempt} <= 2
					&& $session->{attempt} == $session->{leading_no_matches} + 1
				) {
					$session->{leading_no_matches}++;
				}
				if (
					$session->{skip_confirmations_after_two_no_matches}
					&& $session->{leading_no_matches} == 2
					&& $session->{confirmations_required} > 1
				) {
					$session->{confirmations_required} = 1;
					$log->info(
						'first two recognition attempts returned no match; '
						. 'consecutive confirmation is disabled for this session'
					);
				}
			}
		}
		if ($result->{ok} && !$result->{stale} && $session->{attempt} <= $session->{retries}) {
			my $reason = $result->{matched}
				? sprintf(
					'match confirmation %d of %d',
					$session->{confirmations}, $session->{confirmations_required}
				)
				: 'no match';
			$log->info(sprintf(
				'recognition attempt %d returned %s; retrying in %d seconds',
				$session->{attempt}, $reason, $session->{retry_delay_seconds}
			));
			Slim::Utils::Timers::setTimer(
				$session, time() + $session->{retry_delay_seconds},
				\&_retry_recognition, $id
			);
			return;
		}
		_finish_recognition($session, $result);
	});
}

sub _retry_recognition {
	my ($session_timer, $id) = @_;
	my $session = $recognitions{$id} or return;
	my ($bytes, $generation, $pcm_epoch, $pcm_total) =
		Plugins::ShazamCapture::Capture::snapshot_pcm(
			$id, $session->{retry_sample_seconds}
		);
	if (
		!defined $generation || $generation != $session->{generation} ||
		($pcm_epoch || 1) != $session->{pcm_epoch}
	) {
		my $result = $session->{last_result} || { ok=>JSON::XS::true, matched=>JSON::XS::false };
		$result->{stale} = JSON::XS::true;
		return _finish_recognition($session, $result);
	}
	if ($session->{sample_mode} eq 'fresh') {
		my $needed = $session->{retry_sample_seconds} * 32000;
		if (length($bytes || '') < $needed) {
			Slim::Utils::Timers::setTimer(
				$session, time() + 0.1, \&_retry_recognition, $id
			);
			return;
		}
	}
	if (($pcm_total || 0) <= $session->{pcm_total}) {
		$log->info('recognition retry stopped because no new PCM audio arrived');
		return _finish_recognition($session, $session->{last_result});
	}
	$session->{pcm_total} = $pcm_total;
	$session->{attempt}++;
	my $safe = $id; $safe =~ s/[^a-z0-9]+/_/g;
	my $path = File::Spec->catfile(
		$root, 'var', 'tmp',
		sprintf('%s_%d_%d_retry%d.s16le',
			$safe, $generation, int(rand(1e9)), $session->{attempt})
	);
	my $fh;
	if (!open $fh, '>', $path) {
		return _finish_recognition($session, {
			ok=>JSON::XS::false, stage=>'capture',
			error=>"Cannot create plugin-local retry snapshot: $!"
		});
	}
	binmode $fh; print {$fh} $bytes; close $fh;
	$log->info(sprintf(
		'starting recognition attempt %d with %.2f seconds of newest PCM',
		$session->{attempt}, length($bytes || '') / 32000
	));
	my $started = _launch_attempt($session, $path, $session->{retry_sample_seconds});
	if (!$started) {
		unlink $path;
		_finish_recognition($session, {
			ok=>JSON::XS::false, stage=>'worker',
			error=>'Recognition retry worker could not start'
		});
	}
}

sub _result_identity {
	my ($result) = @_;
	my $track = $result->{track};
	return unless ref $track eq 'HASH';
	my $key = $track->{shazam_key};
	return "key:$key" if defined $key && length "$key";
	my @parts = map {
		my $value = defined $_ ? lc "$_" : '';
		$value =~ s/^\s+|\s+$//g;
		$value =~ s/\s+/ /g;
		$value;
	} @{$track}{qw(title artist album)};
	return unless length join('', @parts);
	return 'metadata:' . join("\x1f", @parts);
}

sub _finish_recognition {
	my ($session, $result) = @_;
	my $id = $session->{id};
	Slim::Utils::Timers::killTimers($session, \&_sample_ready);
	Slim::Utils::Timers::killTimers($session, \&_retry_recognition);
	Slim::Utils::Timers::killTimers($session, \&_recognition_timed_out);
	$result ||= { ok=>JSON::XS::false, stage=>'worker', error=>'Recognition failed' };
	if (
		$result->{ok} && $result->{matched} &&
		$session->{confirmations} < $session->{confirmations_required}
	) {
		$result->{matched} = JSON::XS::false;
		$result->{confirmation_failed} = JSON::XS::true;
		$result->{confirmations} = $session->{confirmations};
		$result->{confirmations_required} = $session->{confirmations_required};
	}
	$result->{attempts} = $session->{attempt};
	$result->{retried} = $session->{attempt} > 1 ? JSON::XS::true : JSON::XS::false;
	if (
		$session->{trigger_method} eq 'auto'
		&& $result->{ok} && $result->{matched} && !$result->{stale}
	) {
		my $identity = _result_identity($result);
		$last_auto_identity{$id} = $identity if defined $identity;
	}
	delete $recognitions{$id};
	eval {
		Plugins::ShazamCapture::History::record(
			$id, $session->{generation}, $result, $session->{context}
			, $session->{trigger_method}
		)
	};
	$log->error("could not record recognition history: $@") if $@;
	$log->info('recognition result: '.JSON::XS->new->canonical->encode($result));
	eval { $session->{done}->($result, $session->{generation}) } if $session->{done};
}

sub recognition_running {
	my ($id) = @_;
	$id = lc $id;
	return ($recognitions{$id} || Plugins::ShazamCapture::Worker::running($id)) ? 1 : 0;
}

sub cancel_recognition {
	my ($id, $reason, $expected_trigger_method) = @_;
	$id = lc $id;
	my $session = $recognitions{$id};
	return 0 if $expected_trigger_method && (
		!$session || ($session->{trigger_method} || 'manual') ne $expected_trigger_method
	);
	delete $recognitions{$id};
	if ($session) {
		Slim::Utils::Timers::killTimers($session, \&_sample_ready);
		Slim::Utils::Timers::killTimers($session, \&_retry_recognition);
		Slim::Utils::Timers::killTimers($session, \&_recognition_timed_out);
	}
	Plugins::ShazamCapture::Worker->cancel($id);
	$log->info("recognition cancelled for $id: " . ($reason || 'cancelled'))
		if $session;
	if ($session && ($session->{trigger_method} || 'manual') eq 'manual') {
		my $result = {
			ok=>JSON::XS::false, stale=>JSON::XS::true, stage=>'playback',
			error=>($reason || 'Recognition cancelled')
		};
		eval { $session->{done}->($result, $session->{generation}) }
			if $session->{done};
	}
	return $session ? 1 : 0;
}

sub _pref_int {
	my ($name, $min, $max, $default) = @_;
	my $value = $prefs->get($name);
	$value = $default unless defined $value && "$value" =~ /^\d+$/;
	$value = $min if $value < $min;
	$value = $max if $value > $max;
	return int($value);
}
sub _manual_sample_mode {
	my $mode = $prefs->get('manualSampleMode') || 'buffered';
	return $mode eq 'fresh' ? 'fresh' : 'buffered';
}

sub _write_pcm_snapshot {
	my ($id, $generation, $bytes, $suffix) = @_;
	my $safe = $id; $safe =~ s/[^a-z0-9]+/_/g;
	$suffix ||= 'sample';
	my $path = File::Spec->catfile(
		$root, 'var', 'tmp',
		sprintf('%s_%d_%d_%s.s16le',
			$safe, $generation, int(rand(1e9)), $suffix)
	);
	my $fh;
	return unless open $fh, '>', $path;
	binmode $fh; print {$fh} $bytes; close $fh;
	return $path;
}
sub _history_context {
	my ($client, $state) = @_;
	my $song = eval { $client->streamingSong };
	my $track = $song && eval { $song->currentTrack };
	my $original_track = $song && eval { $song->track };
	my $url = ($state && $state->{url}) || ($track && eval { $track->url }) || '';
	my $original_url = ($original_track && eval { $original_track->url }) || $url;
	my $source = ($track && eval { $track->title }) || '';
	$source ||= eval { Slim::Music::Info::getCurrentTitle($client, $url) } || '';
	return {
		recognized_at => time(),
		player_name   => eval { $client->name } || $client->id,
		source_name   => $source,
		source_url    => _redact($url),
		technical_source => _technical_source($song, $original_url),
	};
}
sub _technical_source {
	my ($song, $url) = @_;
	my $handler = $song && eval { $song->handler };
	my $class = $handler ? "$handler" : '';
	$class =~ s/=.*$//;
	if ($class =~ /^(?:Plugins?|Slim::Plugin)::([^:]+)/) {
		my $plugin = $1;
		my $all = eval { Slim::Utils::PluginManager->allPlugins() } || {};
		my $name = $all->{$plugin} && $all->{$plugin}->{name};
		return eval { string($name) } || $name || $plugin;
	}
	return 'Radio' if ($url || '') =~ m{^https?://}i;
	return $1 if ($url || '') =~ m{^([a-z][a-z0-9+.-]*):}i;
	return '';
}
sub technical_source_for_client {
	my ($client) = @_;
	return '' unless $client;
	my $song = eval { $client->streamingSong };
	my $track = $song && eval { $song->track };
	$track ||= $song && eval { $song->currentTrack };
	my $url = $track && eval { $track->url } || '';
	return _technical_source($song, $url);
}
sub _mode_error {
	my ($mode)=@_;
	return {ok=>0,stage=>'capture',playback_mode=>$mode,error=>$mode eq 'direct'
		? 'The current stream is using direct playback. Enable proxied streaming for this player and restart playback before using audio recognition.'
		: 'The current playback topology cannot be determined confidently; capture was not attempted.'};
}
sub _redact { my $u=shift; $u =~ s/[?#].*$//; $u }

sub getDisplayName { 'PLUGIN_SHAZAMCAPTURE_HISTORY_APP' }

1;
