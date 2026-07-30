package Plugins::ShazamCapture::Artwork;

use strict;
use Encode qw(encode_utf8);
use File::Spec;
use HTTP::Status qw(RC_NOT_FOUND RC_OK);
use POSIX qw(WNOHANG);
use Plugins::ShazamCapture::Runtime;
use Slim::Web::HTTP;
use Slim::Web::Pages;
use Slim::Utils::Timers;

my $root;
my $prefix = 'plugins/ShazamCapture/artwork/';
my %jobs;

sub init {
	my ($class, $plugin_root) = @_;
	$root = $plugin_root;
	my $tmp = File::Spec->catdir($root, 'var', 'tmp');
	if (opendir my $dh, $tmp) {
		while (my $name = readdir $dh) {
			next unless $name =~ /^auto_artwork_[a-z0-9_]+\.jpg$/;
			unlink File::Spec->catfile($tmp, $name);
		}
		closedir $dh;
	}
	Slim::Web::Pages->addRawFunction(
		qr{^/?\Q$prefix\E[a-z0-9_]+\.jpg$},
		\&_serve
	);
}

sub path {
	my ($id) = @_;
	return unless $root;
	my $safe = _safe($id);
	return File::Spec->catfile($root, 'var', 'tmp', "auto_artwork_${safe}.jpg");
}

sub url {
	my ($id) = @_;
	my $path = path($id);
	return unless $path && -f $path;
	my @stat = stat($path);
	return '/' . $prefix . _safe($id) . '.jpg?v='
		. join('-', @stat[1, 7, 9]);
}

sub clear {
	my ($id) = @_;
	$id = lc($id || '');
	if (my $job = delete $jobs{$id}) {
		kill 'TERM', $job->{pid};
		my $reaper = { pid => $job->{pid}, attempts => 0 };
		Slim::Utils::Timers::setTimer(
			$reaper, time() + 0.1, \&_reap_cancelled
		);
	}
	my $path = path($id);
	unlink $path if $path && -f $path;
}

sub compose {
	my ($class, $id, $generation, $artwork_url, $station, $done) = @_;
	$id = lc($id || '');
	return unless ref $done eq 'CODE';
	return $done->(0, $generation)
		unless $root && $id && $artwork_url && $station;
	clear($id) if $jobs{$id};
	my ($python) = Plugins::ShazamCapture::Runtime::python();
	return $done->(0, $generation) unless $python;
	my $helper = File::Spec->catfile($root, 'python', 'artwork.py');
	my $output = path($id);
	my $pid = fork();
	return $done->(0, $generation) unless defined $pid;
	if (!$pid) {
		untie *STDOUT if tied *STDOUT;
		untie *STDERR if tied *STDERR;
		CORE::open(STDOUT, '>', File::Spec->devnull) or POSIX::_exit(126);
		CORE::open(STDERR, '>', File::Spec->devnull) or POSIX::_exit(126);
		exec {$python} (
			$python, $helper, '--url', encode_utf8($artwork_url),
			'--station', encode_utf8($station),
			'--output', $output, '--timeout', '8'
		);
		POSIX::_exit(127);
	}
	$jobs{$id} = {
		pid => $pid, generation => $generation, output => $output,
		done => $done, started => time(),
	};
	Slim::Utils::Timers::setTimer($class, time() + 0.1, \&_poll, $id);
}

sub _poll {
	my ($class, $id) = @_;
	my $job = $jobs{$id} or return;
	my $ended = waitpid($job->{pid}, WNOHANG);
	if (!$ended && time() - $job->{started} <= 18) {
		Slim::Utils::Timers::setTimer($class, time() + 0.1, \&_poll, $id);
		return;
	}
	if (!$ended) {
		kill 'TERM', $job->{pid};
		waitpid($job->{pid}, 0);
	}
	my $ok = $ended > 0 && $? == 0 && -f $job->{output};
	delete $jobs{$id};
	$job->{done}->($ok ? 1 : 0, $job->{generation});
}

sub _reap_cancelled {
	my ($reaper) = @_;
	return if waitpid($reaper->{pid}, WNOHANG);
	return if ++$reaper->{attempts} > 100;
	Slim::Utils::Timers::setTimer(
		$reaper, time() + 0.1, \&_reap_cancelled
	);
}

sub _serve {
	my ($http_client, $response) = @_;
	my ($safe) = $response->request->uri->path =~
		m{^\Q/$prefix\E([a-z0-9_]+)\.jpg$};
	my $path = defined $safe
		? File::Spec->catfile($root, 'var', 'tmp', "auto_artwork_${safe}.jpg")
		: undef;
	return _not_found($http_client, $response) unless $path && -f $path;
	open my $fh, '<', $path or return _not_found($http_client, $response);
	binmode $fh;
	local $/;
	my $image = <$fh>;
	close $fh;
	$response->code(RC_OK);
	$response->content_type('image/jpeg');
	$response->content_length(length $image);
	$response->header('Cache-Control' => 'no-store');
	Slim::Web::HTTP::addHTTPResponse($http_client, $response, \$image);
}

sub _not_found {
	my ($http_client, $response) = @_;
	my $message = 'Artwork not found';
	$response->code(RC_NOT_FOUND);
	$response->content_type('text/plain');
	$response->content_length(length $message);
	Slim::Web::HTTP::addHTTPResponse(
		$http_client, $response, \$message
	);
}

sub _safe {
	my ($id) = @_;
	my $safe = lc($id || '');
	$safe =~ s/[^a-z0-9]+/_/g;
	return $safe;
}

1;
