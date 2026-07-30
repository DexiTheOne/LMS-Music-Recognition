use strict;
use warnings;
use Test::More;

BEGIN {
	package TestLog;
	sub info {}

	package TestPrefs;
	our $flush = 1;
	sub get {
		my ($self, $name) = @_;
		return $flush if $name eq 'flushOnSameStreamMetadata';
		return;
	}

	package Slim::Utils::Log;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"} = sub { return bless {}, 'TestLog' };
	}
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package Slim::Utils::Prefs;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::preferences"} = sub { return bless {}, 'TestPrefs' };
	}
	$INC{'Slim/Utils/Prefs.pm'} = __FILE__;

	package Slim::Utils::Timers;
	our @timer;
	sub setTimer { @timer = @_ }
	sub killTimers {}
	$INC{'Slim/Utils/Timers.pm'} = __FILE__;

	package Slim::Control::Request;
	sub subscribe {}
	$INC{'Slim/Control/Request.pm'} = __FILE__;

	package Slim::Music::Info;
	our $title = '';
	sub getCurrentTitle { return $title }
	$INC{'Slim/Music/Info.pm'} = __FILE__;

	package Plugins::ShazamCapture::Plugin;
	our @cancellations;
	sub cancel_recognition { shift if $_[0] eq __PACKAGE__; push @cancellations, [@_] }
	$INC{'Plugins/ShazamCapture/Plugin.pm'} = __FILE__;

	package Plugins::ShazamCapture::Auto;
	sub publishing { return 0 }
	sub playback_changed {}
	sub metadata_changed {}
	$INC{'Plugins/ShazamCapture/Auto.pm'} = __FILE__;

	package Plugins::ShazamCapture::Capture;
	our $state = {
		awaiting_stream => 0,
		identity => 'stream-1',
		generation => 1,
	};
	our $transition = 0;
	sub state { return $state }
	sub begin_pcm_transition { $transition = 1; return 1 }
	sub end_pcm_transition { $transition = 0; return 1 }
	sub invalidate { return 2 }
	$INC{'Plugins/ShazamCapture/Capture.pm'} = __FILE__;

	package TestTrack;
	sub new { bless {}, shift }
	sub url { return 'test://stream' }

	package TestSong;
	sub new { bless {}, shift }
	sub currentTrack { return TestTrack->new }

	package TestClient;
	sub new { bless { id => $_[1] }, $_[0] }
	sub id { return $_[0]->{id} }
	sub streamingSong { return TestSong->new }

	package TestRequest;
	sub new { bless { client => $_[1], stop => $_[2] }, $_[0] }
	sub client { return $_[0]->{client} }
	sub isCommand { return $_[0]->{stop} }
}

use lib 'lib';
use Plugins::ShazamCapture::Playback;

my $id = '00:11:22:33:44:55';
my $client = TestClient->new($id);

Plugins::ShazamCapture::Playback::_playback_event(
	TestRequest->new($client, 0)
);
is_deeply(
	shift @Plugins::ShazamCapture::Plugin::cancellations,
	[$id, 'Song changed before recognition completed'],
	'playlist song change uses the unified recognition error',
);

$Slim::Music::Info::title = 'First Song';
Plugins::ShazamCapture::Playback::_metadata_event(
	TestRequest->new($client, 0)
);
is(
	scalar @Plugins::ShazamCapture::Plugin::cancellations,
	0,
	'initial metadata establishes a baseline without cancelling',
);

$Slim::Music::Info::title = 'Second Song';
Plugins::ShazamCapture::Playback::_metadata_event(
	TestRequest->new($client, 0)
);
is(
	scalar @Plugins::ShazamCapture::Plugin::cancellations,
	0,
	'uncommitted metadata transition does not cancel',
);
ok($Plugins::ShazamCapture::Capture::transition, 'metadata transition pauses PCM');

my ($timer_client, undef, $callback, @callback_args) =
	@Slim::Utils::Timers::timer;
$callback->($timer_client, @callback_args);
is_deeply(
	shift @Plugins::ShazamCapture::Plugin::cancellations,
	[$id, 'Song changed before recognition completed', 'manual'],
	'stable metadata song change cancels the manual request with the unified error',
);
ok(!$Plugins::ShazamCapture::Capture::transition, 'PCM transition is completed');

done_testing();
