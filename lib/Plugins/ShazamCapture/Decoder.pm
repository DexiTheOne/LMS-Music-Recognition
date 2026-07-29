package Plugins::ShazamCapture::Decoder;

use strict;
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Spec;
use POSIX qw(WNOHANG);
use Plugins::ShazamCapture::Runtime;
use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = logger('plugin.shazamcapture');
my (%decoder, %scheduled);
my $root;

sub init {
	($root) = @_;
}

sub notify {
	my ($id) = @_;
	return unless $root;
	$id = lc $id;
	return if $scheduled{$id};
	$scheduled{$id} = 1;
	Slim::Utils::Timers::setTimer(__PACKAGE__, time() + 0.01, \&_pump, $id);
}

sub status {
	my ($id) = @_;
	my $d = $decoder{lc $id};
	return $d ? 'running' : 'starting';
}

sub invalidate {
	my ($id, $reason) = @_;
	$id = lc $id;
	_stop($id, $reason || 'playback invalidated');
	$scheduled{$id} = 0;
}

sub _start {
	my ($id, $generation) = @_;
	my ($ffmpeg, $runtime_error) = Plugins::ShazamCapture::Runtime::ffmpeg();
	if (!$ffmpeg) {
		$log->error($runtime_error || 'FFmpeg is unavailable');
		return;
	}
	pipe(my $child_in, my $parent_in) or return;
	pipe(my $parent_out, my $child_out) or do { close $child_in; close $parent_in; return };
	my $safe = $id; $safe =~ s/[^a-z0-9]+/_/g;
	my $err = File::Spec->catfile($root, 'var', 'logs', "decoder_${safe}.log");
	my $pid = fork();
	return unless defined $pid;
	if (!$pid) {
		close $parent_in; close $parent_out;
		untie *STDIN if tied *STDIN;
		untie *STDOUT if tied *STDOUT;
		untie *STDERR if tied *STDERR;
		CORE::open(STDIN, '<&', $child_in) or POSIX::_exit(126);
		CORE::open(STDOUT, '>&', $child_out) or POSIX::_exit(126);
		CORE::open(STDERR, '>>', $err) or POSIX::_exit(126);
		exec {$ffmpeg} $ffmpeg, '-hide_banner', '-loglevel', 'error',
			'-i', 'pipe:0', '-vn', '-ac', '1', '-ar', '16000',
			'-c:a', 'pcm_s16le', '-f', 's16le', 'pipe:1';
		POSIX::_exit(127);
	}
	close $child_in; close $child_out;
	fcntl($parent_in, F_SETFL, fcntl($parent_in, F_GETFL, 0) | O_NONBLOCK);
	fcntl($parent_out, F_SETFL, fcntl($parent_out, F_GETFL, 0) | O_NONBLOCK);
	$decoder{$id} = {
		pid=>$pid, input=>$parent_in, output=>$parent_out,
		generation=>$generation, pending=>'',
	};
	$log->info("PCM decoder started for $id generation $generation");
	return $decoder{$id};
}

sub _stop {
	my ($id, $reason) = @_;
	my $d = delete $decoder{$id} or return;
	close $d->{input}; close $d->{output};
	kill 'TERM', $d->{pid};
	waitpid($d->{pid}, WNOHANG);
	$log->info("PCM decoder stopped for $id: $reason");
}

sub _pump {
	my ($class, $id) = @_;
	$scheduled{$id} = 0;
	my $s = Plugins::ShazamCapture::Capture::state($id) or return;
	my $d = $decoder{$id};
	if ($d && $d->{generation} != $s->{generation}) {
		_stop($id, 'stream generation changed');
		$d = undef;
	}
	$d ||= _start($id, $s->{generation});
	return unless $d;

	if (waitpid($d->{pid}, WNOHANG) > 0) {
		_stop($id, 'decoder exited');
		notify($id);
		return;
	}

	$d->{pending} .= Plugins::ShazamCapture::Capture::take_pending($id, $d->{generation}, 65536)
		if length($d->{pending}) < 262144;
	if (length($d->{pending})) {
		my $written = syswrite($d->{input}, $d->{pending});
		if (defined $written && $written > 0) {
			substr($d->{pending}, 0, $written, '');
		} elsif (!defined $written && $! != EAGAIN && $! != EWOULDBLOCK && $! != EINTR) {
			_stop($id, "input error: $!");
			notify($id);
			return;
		}
	}

	for (1..8) {
		my $pcm = '';
		my $read = sysread($d->{output}, $pcm, 65536);
		if (defined $read && $read > 0) {
			Plugins::ShazamCapture::Capture::append_pcm($id, $d->{generation}, $pcm);
			next;
		}
		last if !defined $read && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);
		last;
	}

	notify($id) if length($d->{pending}) || length($s->{pending}) || time() - $s->{last_seen} < 5;
}

1;
