package Plugins::ShazamCapture::Runtime;

use strict;
use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
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
	for my $candidate (_venvs()) {
		my ($venv, $source) = @$candidate;
		my $path = File::Spec->catfile($venv, 'bin', 'python');
		return ($path, undef, $source) if -x $path;
	}
	return (undef, 'Plugin Python is unavailable; configure SHAZAMCAPTURE_PYTHON or create a supported virtual environment');
}

sub ffmpeg {
	return (undef, 'Recognition runtime is not initialized') unless $root;
	if (defined $ENV{SHAZAMCAPTURE_FFMPEG} && length $ENV{SHAZAMCAPTURE_FFMPEG}) {
		return (File::Spec->file_name_is_absolute($ENV{SHAZAMCAPTURE_FFMPEG})
				&& -x $ENV{SHAZAMCAPTURE_FFMPEG})
			? ($ENV{SHAZAMCAPTURE_FFMPEG}, undef, 'environment')
			: (undef, 'SHAZAMCAPTURE_FFMPEG must be an absolute executable path');
	}
	for my $candidate (_venvs()) {
		my ($venv, $source) = @$candidate;
		my @patterns = map {
			File::Spec->catfile(
				$venv, $_, 'python*', 'site-packages',
				'imageio_ffmpeg', 'binaries', 'ffmpeg-*'
			)
		} qw(lib lib64);
		my @found = grep { -x $_ } map { bsd_glob($_) } @patterns;
		return ($found[0], undef, $source) if @found;
	}
	for my $directory (File::Spec->path()) {
		my $candidate = File::Spec->catfile($directory, 'ffmpeg');
		return ($candidate, undef, 'path') if -x $candidate;
	}
	return (undef, 'FFmpeg is unavailable; install imageio-ffmpeg in the selected virtual environment or configure SHAZAMCAPTURE_FFMPEG');
}

sub _venvs {
	my @candidates;
	# LMS replaces InstalledPlugins/Plugins/ShazamCapture during upgrades.
	# Keep the Docker-managed environment beside InstalledPlugins instead.
	my $plugins = dirname($root);
	my $installed = dirname($plugins);
	if (basename($root) eq 'ShazamCapture'
		&& basename($plugins) eq 'Plugins'
		&& basename($installed) eq 'InstalledPlugins') {
		push @candidates, [
			File::Spec->catdir(dirname($installed), 'ShazamCapture-venv'),
			'cache',
		];
	}
	push @candidates, [File::Spec->catdir($root, 'python', 'venv'), 'plugin'];
	return @candidates;
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
