package Plugins::ShazamCapture::Hook;

use strict;
use Slim::Utils::Log;

my $log = logger('plugin.shazamcapture');
my ($original, $installed);

sub install {
	return 1 if $installed;
	require Slim::Player::Client;
	$original = \&Slim::Player::Client::nextChunk;
	die "Slim::Player::Client::nextChunk unavailable" unless $original;
	{
		no warnings 'redefine';
		*Slim::Player::Client::nextChunk = sub {
			my $want = wantarray;
			my (@result, $result);
			if (!defined $want) {
				$original->(@_);
				return;
			} elsif ($want) {
				@result = $original->(@_);
				eval { _observe($_[0], $result[0]) };
				$log->error("observer failed: $@") if $@;
				return @result;
			} else {
				$result = $original->(@_);
				eval { _observe($_[0], $result) };
				$log->error("observer failed: $@") if $@;
				return $result;
			}
		};
	}
	$installed = 1;
	$log->info('installed Slim::Player::Client::nextChunk hook');
	return 1;
}

sub _observe {
	my ($client, $result) = @_;
	return unless ref($result) eq 'SCALAR';
	Plugins::ShazamCapture::Capture::observe($client, $$result);
	Plugins::ShazamCapture::Auto::observe($client);
}
sub installed { $installed ? 1 : 0 }

1;
