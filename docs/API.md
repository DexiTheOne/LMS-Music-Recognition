# Plugin API

`Plugins::ShazamCapture::API` lets another LMS plugin request the same manual
recognition performed by **Recognize Song**. It uses the configured buffered or
fresh sample mode, retry and confirmation settings, timeout, stale-result
checks, and history recording. It never blocks the LMS event loop.

## Availability and version

Load the API at the time it is needed so the calling plugin does not depend on
plugin initialization order:

```perl
my $available = eval {
	require Plugins::ShazamCapture::API;
	Plugins::ShazamCapture::API->available();
};

unless ($available) {
	# Shazam Capture is absent, disabled, or not initialized.
}
```

The initial contract reports:

```perl
my $version = Plugins::ShazamCapture::API->api_version(); # 1
```

Callers should test the major integer version before relying on newer fields.

## Starting recognition

```perl
my $accepted = Plugins::ShazamCapture::API->recognize(
	player_id => $player_id,
	source    => 'Plugins::LikedSongs',
	reason    => 'like',
	context   => {
		playlist_id => $playlist_id,
	},
	callback => sub {
		my ($result, $context, $request) = @_;

		if ($result->{ok} && $result->{matched} && !$result->{stale}) {
			add_to_playlist(
				$context->{playlist_id},
				$result->{track},
			);
		}
		else {
			handle_recognition_failure($result);
		}
	},
);
```

To force a new initial sample regardless of the global manual sample mode, use
the otherwise identical API-only trigger:

```perl
my $accepted = Plugins::ShazamCapture::API->recognize_fresh(
	player_id => $player_id,
	source    => 'Plugins::LikedSongs',
	reason    => 'like',
	callback  => sub {
		my ($result, $context, $request) = @_;
		# Handle the same terminal result contract as recognize().
	},
);
```

`recognize_fresh` clears only the selected player's PCM ring after the request
passes the common admission checks, then waits for the configured initial
sample duration. It shares topology validation, automatic-recognition
exclusion, retries, confirmations, timeouts, stale checks, history recording,
and callback delivery with `recognize`. It does not alter the global setting.
There is no corresponding UI button.

Required arguments:

- `player_id`: ID of the physical LMS player whose proxied audio is captured.
- `source`: stable calling-plugin identifier, normally its Perl namespace.
- `callback`: code reference invoked later with the terminal result.

Optional arguments:

- `reason`: short operation name such as `like`.
- `context`: opaque caller-owned value returned unchanged to the callback. It
  is not logged or stored by Shazam Capture.
- `request_id`: caller correlation ID. Shazam Capture generates one when this
  is omitted.

Control characters are removed from text fields. `player_id`, `source`,
`request_id`, and `reason` are limited to 64, 128, 128, and 256 characters
respectively.

The call returns immediately. Acceptance is not a recognition result:

```perl
{
	ok         => 1,
	accepted   => 1,
	started    => 1,
	request_id => 'shazamcapture-...',
	player_id  => '00:04:20:1f:78:65',
	generation => 12,
}
```

An unaccepted request returns immediately and does not invoke the callback:

```perl
{
	ok       => 0,
	accepted => 0,
	stage    => 'automatic',
	error    => 'Automatic recognition owns this radio stream',
}
```

Other rejection reasons include a missing or disconnected player, invalid
arguments, direct or unknown playback topology, unavailable PCM capture, or
another recognition already running.

## Completion callback

Every accepted request uses the existing manual-recognition session and
receives one terminal callback:

```perl
sub {
	my ($result, $context, $request) = @_;
}
```

`$request` contains the effective `request_id`, normalized `player_id`, and
capture `generation`. A valid song requires all three checks:

```perl
$result->{ok} && $result->{matched} && !$result->{stale}
```

The recognized metadata is in `$result->{track}` and can include `title`,
`artist`, `album`, `shazam_key`, `apple_music_url`, `spotify_url`,
`shazam_url`, and `artwork_url`.

The callback can instead receive an explicit no-match, timeout, playback
change, cancellation, stale result, or worker error. Callers must not retain an
LMS UI request while waiting unless they implement their own terminal timeout;
retain stable IDs in `context` instead.

Callback exceptions are isolated by Shazam Capture and cannot interrupt
playback or the LMS event loop.

## Automatic-recognition interaction

API calls deliberately use the manual path. They are blocked under the same
condition as the UI button: automatic recognition is enabled and currently
eligible for that player's playing Radio or HLS stream. Merely enabling the
global automatic setting does not block an ineligible source.

Successful API matches remain `manual` samples in history. The separate
**API caller** and **API reason** history fields identify how they were
requested. Caller `context` and `request_id` are not stored in the history
database.

The API does not control playback, open the source URL, join synchronization
groups, or create a second capture path.
