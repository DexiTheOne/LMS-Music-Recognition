package Plugins::ShazamCapture::Worker;

use strict;
use File::Spec;
use JSON::XS;
use POSIX qw(WNOHANG);
use Plugins::ShazamCapture::Runtime;
use Slim::Utils::Timers;

my (%jobs, %last, %start_error);

sub running { $jobs{lc $_[0]} ? 1 : 0 }
sub last { $last{lc $_[0]} }
sub start_error { $start_error{lc $_[0]} }
sub cancel {
	my ($class, $id) = @_;
	$id = lc $id;
	my $j = delete $jobs{$id} or return 0;
	kill 'TERM', $j->{pid};
	my $reaper = { pid => $j->{pid}, attempts => 0 };
	Slim::Utils::Timers::setTimer($reaper, time() + 0.1, \&_reap_cancelled);
	unlink grep { defined $_ && length $_ } @{$j}{qw(out err input)};
	return 1;
}

sub _reap_cancelled {
	my ($reaper) = @_;
	return if waitpid($reaper->{pid}, WNOHANG);
	return if ++$reaper->{attempts} > 100;
	Slim::Utils::Timers::setTimer($reaper, time() + 0.1, \&_reap_cancelled);
}

sub start {
	my ($class, $id, $generation, $input, $root, $timeout, $sample_seconds, $save_debug_wav, $done) = @_;
	$id = lc $id;
	return 0 if $jobs{$id};
	delete $start_error{$id};
	my ($python, $runtime_error) = Plugins::ShazamCapture::Runtime::python();
	if (!$python) {
		$start_error{$id} = $runtime_error || 'Plugin Python is unavailable';
		return 0;
	}
	my $safe = $id; $safe =~ s/[^a-z0-9]+/_/g;
	my $out = File::Spec->catfile($root, 'var', 'tmp', "result_${safe}_$$.json");
	my $err = File::Spec->catfile($root, 'var', 'tmp', "result_${safe}_$$.err");
	my $helper = File::Spec->catfile($root, 'python', 'recognize.py');
	my $pid = fork();
	if (!defined $pid) {
		$start_error{$id} = "Recognition worker could not fork: $!";
		return 0;
	}
	if (!$pid) {
		# LMS ties the process-wide output handles to its log trap. The child
		# must detach its inherited copies before redirecting worker output.
		untie *STDOUT if tied *STDOUT;
		untie *STDERR if tied *STDERR;
		CORE::open(STDOUT, '>', $out) or POSIX::_exit(126);
		CORE::open(STDERR, '>', $err) or POSIX::_exit(126);
		my @args = (
			$python, $helper, '--input', $input, '--timeout', "$timeout",
			'--sample-seconds', "$sample_seconds"
		);
		push @args, '--save-debug-wav' if $save_debug_wav;
		exec {$python} @args;
		POSIX::_exit(127);
	}
	$jobs{$id} = { pid=>$pid, out=>$out, err=>$err, input=>$input, generation=>$generation,
		started=>time(), timeout=>$timeout+5, done=>$done };
	Slim::Utils::Timers::setTimer($class, time()+0.25, \&_poll, $id);
	return 1;
}

sub _poll {
	my ($class, $id) = @_;
	my $j = $jobs{$id} or return;
	my $ended = waitpid($j->{pid}, WNOHANG);
	if (!$ended && time()-$j->{started} <= $j->{timeout}) {
		Slim::Utils::Timers::setTimer($class, time()+0.25, \&_poll, $id); return;
	}
	if (!$ended) { kill 'TERM', $j->{pid}; waitpid($j->{pid}, 0) }
	my $raw = '';
	if (open my $fh, '<', $j->{out}) { local $/; $raw = <$fh>; close $fh }
	my $result = eval { JSON::XS->new->decode($raw) };
	$result ||= { ok=>JSON::XS::false, stage=>'worker', error=>($ended ? 'Malformed worker output' : 'Worker timed out') };
	unlink $j->{out}, $j->{err}, $j->{input};
	$last{$id} = $result;
	delete $jobs{$id};
	eval { $j->{done}->($result, $j->{generation}) } if $j->{done};
}

1;
