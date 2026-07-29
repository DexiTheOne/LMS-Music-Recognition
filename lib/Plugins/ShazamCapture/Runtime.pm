package Plugins::ShazamCapture::Runtime;

use strict;
use Cwd qw(abs_path);
use File::Glob qw(bsd_glob);
use File::Spec;

my $root;

sub init {
	($root) = @_;
	$root = abs_path($root) || $root;
}

sub python {
	return (undef, 'Recognition runtime is not initialized') unless $root;
	if (defined $ENV{SHAZAMCAPTURE_PYTHON} && length $ENV{SHAZAMCAPTURE_PYTHON}) {
		return (File::Spec->file_name_is_absolute($ENV{SHAZAMCAPTURE_PYTHON})
				&& -x $ENV{SHAZAMCAPTURE_PYTHON})
			? ($ENV{SHAZAMCAPTURE_PYTHON}, undef, 'environment')
			: (undef, 'SHAZAMCAPTURE_PYTHON must be an absolute executable path');
	}
	my $path = File::Spec->catfile($root, 'python', 'venv', 'bin', 'python');
	return (-x $path)
		? ($path, undef, 'plugin')
		: (undef, 'Plugin Python is unavailable; create python/venv with a supported Python interpreter');
}

sub ffmpeg {
	return (undef, 'Recognition runtime is not initialized') unless $root;
	if (defined $ENV{SHAZAMCAPTURE_FFMPEG} && length $ENV{SHAZAMCAPTURE_FFMPEG}) {
		return (File::Spec->file_name_is_absolute($ENV{SHAZAMCAPTURE_FFMPEG})
				&& -x $ENV{SHAZAMCAPTURE_FFMPEG})
			? ($ENV{SHAZAMCAPTURE_FFMPEG}, undef, 'environment')
			: (undef, 'SHAZAMCAPTURE_FFMPEG must be an absolute executable path');
	}
	my @patterns = map {
		File::Spec->catfile(
			$root, 'python', 'venv', $_, 'python*', 'site-packages',
			'imageio_ffmpeg', 'binaries', 'ffmpeg-*'
		)
	} qw(lib lib64);
	my @found = grep { -x $_ } map { bsd_glob($_) } @patterns;
	return ($found[0], undef, 'plugin') if @found;
	for my $directory (File::Spec->path()) {
		my $candidate = File::Spec->catfile($directory, 'ffmpeg');
		return ($candidate, undef, 'path') if -x $candidate;
	}
	return (undef, 'FFmpeg is unavailable; install imageio-ffmpeg in python/venv or configure SHAZAMCAPTURE_FFMPEG');
}

sub status {
	my ($python, $python_error, $python_source) = python();
	my ($ffmpeg, $ffmpeg_error, $ffmpeg_source) = ffmpeg();
	return {
		python_ready  => $python ? 1 : 0,
		python_source => $python_source || '',
		python_path   => $python || '',
		python_error  => $python_error || '',
		ffmpeg_ready  => $ffmpeg ? 1 : 0,
		ffmpeg_source => $ffmpeg_source || '',
		ffmpeg_path   => $ffmpeg || '',
		ffmpeg_error  => $ffmpeg_error || '',
	};
}

1;
