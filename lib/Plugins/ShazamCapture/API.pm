package Plugins::ShazamCapture::API;

use strict;

use Plugins::ShazamCapture::Plugin;
use Slim::Player::Client;

our $VERSION = 1;
my $request_sequence = 0;

sub api_version {
	return $VERSION;
}

sub available {
	return Plugins::ShazamCapture::Plugin::initialized() ? 1 : 0;
}

sub recognize {
	my ($class, %args) = @_;
	return $class->_recognize(undef, %args);
}

sub recognize_fresh {
	my ($class, %args) = @_;
	return $class->_recognize('fresh', %args);
}

sub _recognize {
	my ($class, $sample_mode, %args) = @_;
	my $player_id = _text($args{player_id}, 64);
	return _rejected('player_id is required') unless length $player_id;

	my $source = _text($args{source}, 128);
	return _rejected('source is required') unless length $source;

	my $callback = $args{callback};
	return _rejected('callback must be a code reference')
		unless ref $callback eq 'CODE';
	return _rejected('Shazam Capture is not initialized') unless available();

	my $client = Slim::Player::Client::getClient($player_id);
	return _rejected('The selected player is not connected') unless $client;

	my $reason = _text($args{reason}, 256);
	my $request_id = _text($args{request_id}, 128);
	$request_id = _request_id($client->id) unless length $request_id;
	my $context = $args{context};

	my $started = Plugins::ShazamCapture::Plugin::start_recognition(
		$client,
		sub {
			my ($result, $generation) = @_;
			$callback->($result, $context, {
				request_id => $request_id,
				player_id  => lc $client->id,
				generation => $generation,
			});
		},
		'manual',
		{
			api_source => $source,
			api_reason => $reason,
		},
		{
			sample_mode => $sample_mode,
		},
	);
	return {
		%{$started || {}},
		ok       => 0,
		accepted => 0,
		error    => ($started && $started->{error})
			|| 'Recognition could not be started',
	} unless $started && $started->{ok};
	return {
		%$started,
		accepted   => 1,
		request_id => $request_id,
		player_id  => lc $client->id,
	};
}

sub _rejected {
	my ($error) = @_;
	return {
		ok       => 0,
		accepted => 0,
		stage    => 'api',
		error    => $error,
	};
}

sub _text {
	my ($value, $maximum) = @_;
	return '' unless defined $value && !ref $value;
	$value = "$value";
	$value =~ s/[\x00-\x1f\x7f]+/ /g;
	$value =~ s/^\s+|\s+$//g;
	$value = substr($value, 0, $maximum) if length($value) > $maximum;
	return $value;
}

sub _request_id {
	my ($player_id) = @_;
	my $safe = lc($player_id || 'player');
	$safe =~ s/[^a-z0-9]+//g;
	$request_sequence = ($request_sequence + 1) % 1_000_000;
	return sprintf(
		'shazamcapture-%s-%d-%06d',
		$safe || 'player', time(), $request_sequence
	);
}

1;
