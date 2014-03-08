#!/usr/bin/perl -w
#
######################
# SBA - Simple Build Agent (in Perl)
# 
# v1.10 - 08-Mar-14
# v1.00 - 07-Mar-14
# v0.01 - 03-Mar-14
# 
# SBA is Copyright (c)2014 by Maxim Paperno. All rights reserved.
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
######################
package SBA;

use 5.010_001;
use strict;
use warnings;
use Cwd qw(abs_path chdir);
use File::Basename qw(dirname);
use POSIX qw(strftime);
use Getopt::Long qw(GetOptions GetOptionsFromString :config pass_through);
use Data::Dump qw(pp);
use Config::IniFiles;
use Pod::Usage;
use Net::FTP;
use Mail::Sender;
use Tie::File;

# "globals"
my $DEBUG = 0;
my $OUTPUT = "";				# logged output collector
my $STATUS = 0;					# exit status
my $QUIET = 0;					# suppress all output and redirect STDOUT to &log()
my $LOG_H;						# logger handle
(my $PROG = $0) =~ s/.*[\/\\]//; # self name

# handle all output and some signals internally
$SIG{__WARN__} = \&_warn;
$SIG{__DIE__}  = \&_die;
*STDERR = \&_err;
*STDOUT = \&_out if $QUIET;

# MAIN: {

#
# SETUP
#

# settings (these can be changed via as cmd-line options or config file [settings] section)
my $configFile	= "./sba.ini";		# this is where to read the build config(s) from (required)
my $forceBuild	= 0;				# always (re-)build
my $logFolder	= "./log";			# folder name for generated build output logs (absolute, or relative to working folder). Blank to disable logging.
my %notify  = (
	always	=> 0,					# set to true to notify even if nothing was done (no new version detected)
	recip	=> "",					# one or more e-mail addresses to notify about build status. Blank to disable notifications.
	server	=> "",					# mail server to use for notifications
	port	=> "",					# mail server  port, blank for default
	user	=> "",					# username for mail server auth, if required
	pass	=> "",					# password for mail server auth, if required
	usetls	=> 0,					# enable to use TLS/SSL transport
	sender	=> "<>",				# sender address (default is null)
	subject	=> "[SBA] Build", 		# e-mail subject prefix
	msg		=> ""					# used internally, not settable
);

# per-build config defaults (these can be changed via config file [build-default] section)
my %buildConfigDefaults = (
	name			=> "",			# build name
	dir				=> "",			# build directory (optional)
	clean			=> "",			# clean command
	build			=> "",			# build command
	deploy			=> "",			# deploy (package) command
	distrib			=> "",			# distribute command
	finish			=> "",			# finish (last) command
	incremental		=> 0,			# incremental build (don't clean first)
	force			=> 0,			# force build even if no update
	enable			=> 1,			# enabled/disabled
	last_build_ver	=> "",			# vcs version last built successfully (string comparison)
	last_build_dt	=> "",			# timestamp of last succeful build
	last_run_stat	=> 0,			# final status of last run
	last_run_dt		=> 0,			# timestamp of last run
	
# rest are for internal use only, these are not read/written from/to config file
	status			=> 0,			
	cfg_section		=> "",			
);

# other script-wide defaults
(my $logFileName = $PROG) =~ s/\..+$//;
my $logFileSfx	= ".log";
my $logNull = ($^O eq "MSWin32") ? "NUL" : "/dev/null";
my $svnUpdtCmd = "svn update -r HEAD --force";


# declarations/misc
my @buildConfigs;
my %cfg;			# tied to config file
my $workFolder;
my $tmp;
my $localRev = 0;
my $remoteRev = 0;
my $forceDbg = 0;
my $disableLog = 0;
my %status = (
	this		=> 0,
	vcs_udate	=> 0,
	builds_ttl	=> 0,
	builds_ok	=> 0,
	builds_err	=> 0
);


#
# CONFIG
#

# main script settings storage (some values might also be stored in global vars)
my %options = (
	"config"		=> \$configFile,
	"log-folder"	=> \$logFolder,
	"notify-always"	=> \$notify{always},
	"notify-to"		=> \$notify{recip},
	"notify-server"	=> \$notify{server},
	"notify-port"	=> \$notify{port},
	"notify-usetls"	=> \$notify{usetls},
	"notify-user"	=> \$notify{user},
	"notify-pass"	=> \$notify{pass},
	"notify-from"	=> \$notify{sender},
	"notify-subj"	=> \$notify{subject},
	"force-build"	=> \$forceBuild,
	"debug"			=> \$DEBUG,
	"quiet"			=> \$QUIET
);

# option arguments syntax passed to Getopt::Long::GetOptions()
my @optspec = (
	'config|c=s',
	'log-folder|l:s',
	'notify-to|to=s',
	'notify-server|server=s',
	'notify-port|port:n',
	'notify-user|user=s',
	'notify-pass|pass=s',
	'notify-from|from:s',
	'notify-subj|subj=s',
	'notify-usetls|usetls:1',
	'notify-always|always:1',
	'force-build|force|f:1',
	'debug|d:1',
	'quiet|q:1'
);

# first only check a few cmd-line arguments, the rest are read from config file first
# we later run GetOptions again so cmd-line can override config file.
pod2usage(1) unless 
	Getopt::Long::GetOptions(\%options, 
							'config|c=s',
							'debug|d',
							'quiet|q',
							'help|h|?',
							'man'
	);

pod2usage(1) if $options{help};
pod2usage(-exitval => 0, -verbose => 2) if $options{man};

$forceDbg = $DEBUG;

# process config file

tie %cfg, 'Config::IniFiles', ( 
				-file => $configFile, 
				-allowcontinue => 1, 
#				-allowedcommentchars => '#', 
#				-handle_trailing_comment => 1 
)
	or &_die("Could not read config file $configFile : $!");

{
	my ($s, %h, $k, $v, $t);
	foreach $s (tied(%cfg)->Sections()) {
		%h = %{$cfg{$s}};
		if ($s eq "settings") {
			$t = "";
			$t .= "--".$k." ".$v." " while (($k, $v) = each %h);
			Getopt::Long::GetOptionsFromString($t, \%options, @optspec);
		} elsif ($s eq "build-default") {
			@buildConfigDefaults{keys %h} = values %h;
		} else {
			$t = {%buildConfigDefaults};
			$t->{cfg_section} = $t->{name} = $s;
			@$t{keys %h} = values %h;
			push @buildConfigs, $t;
		}
	}
}

# now let any command-line arguments override config file
pod2usage(1) unless 
	Getopt::Long::GetOptions(\%options, @optspec);

# force debug if it was specified on cmd line
$DEBUG = $forceDbg || $DEBUG;
# redirect stdout if quiet
*STDOUT = \&_out if $QUIET;

# debug output of full config
&_dbg(pp("buildConfigDefaults hash:", \%buildConfigDefaults, 
			"buildConfigs array:", \@buildConfigs, 
			"options hash:", \%options)
);

#
# START
#

# set working folder based on location of config file
$workFolder = dirname(abs_path($configFile));

chdir $workFolder 
	or &_die("Could not change to directory $workFolder");

# open the main log file, if any
if ($logFolder ) {
	$logFolder = $workFolder ."/". $logFolder;
	validateDir($logFolder)
		or &_die("Failed to create log directory: $!");
	my $fullLogfilePath = $logFolder ."/". $logFileName . $logFileSfx;
	open ($LOG_H, '>', $fullLogfilePath)
		or &_die("Could not open log file $fullLogfilePath : $!");

} else {
	$disableLog = 1;
}

&log("Starting...");
&log("Found config file at $configFile");
&log("Working folder is $workFolder");

# get local svn version
&log("Checking local version...");
$localRev = &svnVersion("local");
&log("Local revision: $localRev");

# get remote svn version
&log("Checking remote version...");
$remoteRev = &svnVersion("remote");
&log("Remote revision: $remoteRev");

# compare revision numbers
if ($localRev == $remoteRev) {
	&log("Already have latest version.");
} else {
	# try an SVN update now
	&log("Trying: $svnUpdtCmd");
	$tmp = ($disableLog) ? $logNull : $logFolder ."/vcs-update". $logFileSfx;
	$tmp = $svnUpdtCmd ." >". $tmp ." 2>&1";
	if (system($tmp) == 0) {
		$status{vcs_udate} = 1;
	} elsif (&log("Re-trying: $svnUpdtCmd") && system($tmp) == 0) { # 2nd try
		$status{vcs_udate} = 1;
	} else {
		&_die("SVN update failed with: $?");
	}
	if ($status{vcs_udate} == 1) {
		$localRev = &svnVersion("local");
		&log("Repo update complete. New local revision: $localRev"); 
	}
}

# start building requested config(s)
{
	my ($b,
		$buildName, 
		$macros,
		$logRoot, 
		$logFile,
		$cmd,
		$cmdRslt,
		$cmdOutput,
		$typ,
		$typCmd
	),
	my $config_rewrite = 0,
	my $b_count = 0,
	my $t_count = 0;
	
	for $b (@buildConfigs) {
		$b_count++;
		$t_count = 0;
		$cmdRslt = 0;
		$buildName = $b->{name};
		$logRoot = $logFolder ."/". $buildName;
		$logFile = $logNull;
		$b->{status} = 0;
		
		if ($b->{name} eq "") {
			&log("--$b_count-- No name found for this config, skipping.");
			goto FINISH_CONFIG;
		} elsif ($b->{enable} == 0) {
			&log("--$b_count-- $buildName is disabled, skipping.");
			goto FINISH_CONFIG;
		} elsif ($b->{clean} eq "" && $b->{build} eq "" && $b->{deploy} eq "" && $b->{distrib} eq "" && $b->{finish} eq "") {
			&_warn(2, "--$b_count-- No commands found for $buildName, skipping.");
			goto FINISH_CONFIG;
		} elsif (!$b->{force} && !$forceBuild && $b->{last_build_ver} eq $localRev) { #!$status{vcs_udate}
			&log("--$b_count-- No updates for $buildName, skipping. (last-built-ver: $b->{last_build_ver}; local-ver:$localRev)");
			goto FINISH_CONFIG;
		}
		# is build folder specified in config? make sure it exists
		if ($b->{dir} ne "") {
			if (!validateDir($b->{dir})) {
				&_err("--$b_count-- Failed to create build directory, skipping this build.");
				goto FINISH_CONFIG;
			}
		}
		
		&log("==$b_count== Starting to process $buildName with version $localRev");
		
		foreach $typ (qw(clean build deploy distrib finish)) {
			$t_count++;
			$typCmd = $b->{$typ};
			# skip over blank commands, or clean step if incremental build
			next if ($typCmd eq "" || ($typ eq "clean" && $b->{incremental}));
			
			$b->{status} = $t_count; # keep track of current step
			# set log file, if not disabled (default is nul)
			$logFile = $logRoot ."-". $typ . $logFileSfx if (!$disableLog);

			# replace embedded macros
			$tmp = evalMacros($typCmd, $b);
			# eval backtick`ed expressions in the command line (save an un-eval copy for logging to protect pswds) 
			($cmd = $tmp) =~ s/(`.+`)/eval($1)/eg;
			
			&log("~~$b_count~~ $typ step command: " . $tmp);
			&_dbg("expanded cmd: <$cmd>");
			
			# check if special case for built-in ftp client
			if ($cmd =~ s/^sba_ftp //i) { 
				($cmdRslt, $cmdOutput) = ftpSend($cmd =~ /(`.+`|\S+)/g);
				&_dbg("ftpSend returned: \n". $cmdOutput);
				if ( open (my $tmp_h, '>', $logFile) ) {
					print $tmp_h $cmdOutput;
					close ($tmp_h);
					undef($tmp_h);
				} else { 
					&_warn("Could not write to $typ log file: $!");
				}
			}
			# otherwise just execute the command 
			else {
				$cmdRslt = system($cmd ." >". $logFile . " 2>&1");
			}
			
			# check result
			if ($cmdRslt == 0) {
				$b->{status} = 10 * $t_count; # success
				&log("++$b_count++ $typ step completed");
			} else {
				$b->{status} = 10 * $t_count + 100; # fail
				&_err("!!$b_count!! $typ step FAILED with error: $cmdRslt." . (!$disableLog ? " Check $logFile for details." : ""));
				last;
			}
			
		} # loop each command type
	
		&log("==$b_count== Finished with $buildName");
		
		FINISH_CONFIG : {
			# update config file with status info
			$cfg{$b->{cfg_section}}{last_run_stat} = $b->{status};
			$cfg{$b->{cfg_section}}{last_run_dt} = strftime("%m/%d/%y %H:%M:%S", localtime);
			if ($b->{status} >= 10 && $b->{status} < 100) {
				$cfg{$b->{cfg_section}}{last_build_ver} = $localRev;
				$cfg{$b->{cfg_section}}{last_build_dt} = $cfg{$b->{cfg_section}}{last_run_dt};
			}
			if (tied( %cfg )->RewriteConfig()) {
				$config_rewrite = 1;
			} else { &_err("Could not update config file: $!"); }
		}
	} # end of @buildConfigs loop

	# prettyify rewritten config file
	if ($config_rewrite) {
		if (tie my @newcfg, 'Tie::File', $configFile) {
			s/([^=\s]+)=/sprintf("%-15s = ", $1)/e foreach @newcfg;
			untie @newcfg;
		}
		else { &_warn("Could not prettify config file: $!"); }
	}

} # end configs proc block

&_dbg(pp("Result buildConfigs array:", \@buildConfigs));

#} # END MAIN:

END: {

	# notify
	eval {
		my $doNotice = 1;
		if ($notify{recip} ne "" && $notify{server} ne "") {
			# examine build config for status
			for $b (@buildConfigs) {
				$status{builds_ttl}++;
				if ($b->{status} >= 100) {		# errors
					$status{builds_err}++;
				} elsif ($b->{status} >= 10) {	# success statuses
					$status{builds_ok}++;
				} elsif ($b->{status} > 0) {	# was in middle of a step
					$status{builds_err}++;
				}
			}
			# subject suffix to add
			$notify{subject} .= ": ";
			if ($status{this} != 0) {
				$notify{subject} .= "CRITICAL";
			} elsif ($status{vcs_update}) {
				$notify{subject} .= "VCS UPDATE";
				if ($status{builds_err} > 0) {
					$notify{subject} .= "-ERRORS"; }
				elsif ($status{builds_ok} > 0) {
					$notify{subject} .= "-OK"; }
			} elsif ($status{builds_err} > 0) {
				$notify{subject} .= "BUILD FAIL";
			} elsif ($status{builds_ok} > 0) {
				$notify{subject} .= "BUILD OK";
			} else  {
				$notify{subject} .= "No Updates";
				$doNotice = $notify{always};
			}
			if ($doNotice) {
				# append totals count to subject
				$notify{subject} .= " (ttl: ". $status{builds_ttl} .
									  " ok: ". $status{builds_ok} .
									  " err: ". $status{builds_err} .
									  " skp: ". ($status{builds_ttl} - $status{builds_err} - $status{builds_ok}) .")";
				&log(3, "Sendng notifcation...");
				# send notice
				&notify(\%notify);
			} else {
				&log(3, "Skipping notifcation (no updates).");
			}
		} else {
			&log(3, "Skipping notifcation (no recipient or server).");
		}
	};
	&_err("Error trying to notify: $@") if $@;
	
	&log("Done, exiting.");
	
	close ($LOG_H) if ($LOG_H);
	
	exit $status{this};

} # END

#
# FUNCTIONS
#

# handle all script output here, includign fatal errors. Use instead of print/warn/die().
# Usage: &log([severity,] text);
# severity levels: 
# 	0=fatal (force exit); 1=error; 2=warning; 3=info (default); 4=verbose info; 5=debug;
# Sll output is sent to STDOUT unless $QUIET is true. All output is saved to $OUTPUT. 
# All output is sent to $LOG_H if it is a valid output handle.
sub log {
	#pp(\@_);
	my $lvl = ($_[0] =~ /^\d$/) ? shift : 3;
	my $msg = shift;
	return 0 if (!$msg || ($lvl == 5 && !$DEBUG));
	
	my $haveLog = ($LOG_H && tell($LOG_H) != -1);
	my ($clr_p, $clr_f, $clr_l) = caller;
	my $dt = strftime "%m/%d/%y %H:%M:%S", localtime;
	my $typName = "INF";
	for ($lvl) {
		when (0) { $typName = "CRT"; }
		when (1) { $typName = "ERR"; }
		when (2) { $typName = "WRN"; }
		when (5) { $typName = "DBG"; }
	}

	eval {
		my $out = $clr_p;
		$out .= "@". $clr_l if $DEBUG;
		$out .= " ". $typName .": ". $msg ."\n";
		my $dsout = $dt . " " . $out; # date-stamped version
		
		# print everything to stdout unless silenced
		print STDOUT $out if !$QUIET;
		
		# print to log handle if we have one
		print $LOG_H $dsout if $haveLog;
	
		# save to global output
		$OUTPUT .= $dsout; 
		
		if ($lvl == 0) {
			$status{this} = -1;
			goto END;
		}
		return 0;
	};
	if ($@) {
		print "PANIC: Failure in log() function: $@ \n";
		exit 1;
	}
}

# some aliases for the above &log function
sub _out { &log(3, @_); }	# STDOUT handler
sub _warn { &log(2, @_); }	# SIG_WARN handler
sub _err { &log(1, @_); }	# STDERR handler
sub _die { &log(0, @_); }	# SIG_DIE handler
sub _dbg { &log(5, @_); }	# debug shortcut


# get revision number from svn repo
# Returns: numeric revision number
# Usage: svnVersion("local|remote");
sub svnVersion {
	my $type = shift(@_);
	my $rev;
	my $ret = "";
	
	if ($type eq "local") {
		$rev = `svn info`;
	} else {
		$rev = `svn info -r HEAD`;
	}
	if ($?) { &_die("Could not get svn info."); }
	($ret) = ($rev =~ m/^Revision..(\d+)$/m);
	
	return $ret;
}

# check that a directory exists and try to create it if not
# returns true if dir existed or was created, false otherwise
# Usage: validateDir("./path/to/folder")
sub validateDir {
	my $dir = shift(@_);
	my $ret = 0;
	$ret = 1 if (-e $dir || mkdir $dir);
	return $ret;
}

# Replace embedded variables (macros) in given string with values from hash reference
# Returns: input string with macros replaced by values from $hashref
# Usage: evalMacros("my string wtih $myVar", $hashref)
sub evalMacros {
	my ($in, $macros) = @_;
	
#	$in =~ s/(`.+`)/eval($1)/eg;
	$in =~ s/\$(\w+)/ exists $macros->{$1} ? $macros->{$1} : $1 /eg;
	# do it again to parse resulting embedded macros (double stuffed! :)
	$in =~ s/\$(\w+)/ exists $macros->{$1} ? $macros->{$1} : $1 /eg;
	return $in;
}

# Mini FTP client
# Usage:
# ftpSend( remote_host user password remote_path [<bin|asc>] [permission_mask] [file1] [file2] [...] );
# see docs about how to call this from a build config distribCmd directive.
sub ftpSend {
	my $ret = 1; # return code: 0: success; 1: failure
	my $retMsg = "";
	my $ftp;
	my $file;
	my $cmdResult;
	my @expanded;
	
	my $host = shift;
	my $user = shift;
	my $pass = shift;
	my $dir = shift;
	my $trans_mode = ($_[0] && $_[0] =~ /(asc|bin)/) ? shift : "bin";
	my $pmask = ($_[0] && $_[0] =~ /\d+/) ? shift : 0;
	my @files = @_;
	
	if (!@files) {
		$retMsg .= "ftpSend: ERROR: no file to send or not enough arguments. \n";
		goto EXIT;
	}

	$retMsg .= "ftpSend: connect $host \n";
	unless ($ftp = Net::FTP->new($host)) { 
		$retMsg .= "ftpSend: ERROR: Cannot connect to $host: $@ \n"; 
		goto EXIT; 
	}
	$retMsg .= "ftpSend: < ". $ftp->message;
	
	$retMsg .= "ftpSend: > login $user \n";
	unless ($ftp->login($user,$pass)) { 
		$retMsg .= "ftpSend: ERROR: Cannot login: ". $ftp->message; 
		goto EXIT; 
	}
	$retMsg .= "ftpSend: < ". $ftp->message;

	$dir =~ s/\/$//; # strip trailing slash, if any
	$retMsg .= "ftpSend: > cwd $dir \n";
	if ($ftp->cwd($dir) == 0) { 
		# if can't cwd the first time, try to mkdir
		$retMsg .= "ftpSend: > mkdir $dir \n";
		if ($ftp->mkdir($dir, 1)) {
			$retMsg .= "ftpSend: < ". $ftp->message;
			# if we need to set permissions, have to iterate over each created folder to do so (better way?)
			if ($pmask) {	
				foreach (grep(length, split('/', $dir))) {
					next if ($_ eq "." || $_ eq "..");
					$retMsg .= "ftpSend: > site CHMOD $pmask $_ \n";
					$ftp->site("CHMOD $pmask $_");
					$retMsg .= "ftpSend: < ". $ftp->message;
					$retMsg .= "ftpSend: > cwd $_ \n";
					$ftp->cwd($_);
					$retMsg .= "ftpSend: < ". $ftp->message;
				}
			}
		} else {
			$retMsg .= "ftpSend: mkdir error: ". $ftp->message; 
		}
		
		# now try cwd again
		$retMsg .= "ftpSend: > cwd $dir \n";
		unless ($ftp->cwd($dir)) { 
			$retMsg .= "ftpSend:ERROR: Cannot change to working directory: ". $ftp->message; 
			goto EXIT; 
		}
		$retMsg .= "ftpSend: < ". $ftp->message;
	} else {
		$retMsg .= "ftpSend: < ". $ftp->message;
	}

	($trans_mode eq "asc") ? $ftp->ascii : $ftp->binary;
	$retMsg .= "ftpSend: < ". $ftp->message;

	while (@files) {
		$file = shift @files;
		if ($file =~ /\*/) {		# handle wildcards
			@expanded = `ls $file 2>&1`;
			if ($expanded[0] =~ /not found/) {
				$retMsg .= "ftpSend: ERROR: no matches for $file \n";
			} else {
				chomp foreach (@expanded); # remove trailing newlines
				@files = (@files, @expanded);
			}
		} elsif (-f $file && -r $file) {	# send if file and readable
			$ret = 1; # reset to failed status in case previous file(s) succeeded
			$retMsg .= "ftpSend: > put $file \n";
			if ($cmdResult = $ftp->put($file)) {
				$retMsg .= "ftpSend: < ". $ftp->message;
				if ($pmask) {
					$retMsg .= "ftpSend: > site CHMOD $pmask $cmdResult \n";
					$ftp->site("CHMOD $pmask $cmdResult");
					$retMsg .= "ftpSend: < ". $ftp->message;
				}
				$ret = 0; # success (hopefully)
			} else {
				$retMsg .= "ftpSend: Cannot send file, response: ". $ftp->message;
			}
		} else {
			$retMsg .= "ftpSend: ERROR: <$file> not found or is a folder. \n";
		}
	}

	$retMsg .= "ftpSend: > quit \n";
	$ftp->quit;
	$retMsg .= "ftpSend: < ". $ftp->message;
	$retMsg .= "ftpSend: Session finished.\n";

	EXIT: {
		return ($ret, $retMsg);
	}
}

# send notifactions about build job
# Usage:
sub notify {
	my $sender;
	
	my $opts = shift;
	my $senderOpts = {
		smtp => $opts->{server},
		from => $opts->{sender},
		to   => $opts->{recip},
		subject => $opts->{subject},
		TLS_allowed => $opts->{usetls},
		on_errors => 'die',
		msg => $OUTPUT
	};
	
	if ($opts->{user} ne "") {
		$senderOpts->{authid} = $opts->{user};
		$senderOpts->{authpwd} = $opts->{pass};
	}
	
	if ($senderOpts->{smtp} eq "" || $senderOpts->{to} eq "") {
		&_warn("notify ERROR: No server specified or no one to send to.");
		return;
	}
	
	eval {
		$sender = new Mail::Sender();
		$sender->MailMsg($senderOpts);
#		&_dbg(pp(\$sender));
		&log("Notifcation sent to <". $opts->{recip} ."> with response: ". $sender->{message_response});
	} or &_err($@);
	
	return;
}

#
# DOCUMENTATION
#

=pod

=head1 NAME

 
 Simple Build Agent (in Perl)
 

=head1 DESCRIPTION
 
F<SBA> is designed as a very basic "build server" (or L<CI|http://en.wikipedia.org/wiki/Continuous_integration>, if you prefer).
It can compare a local and remote code repo (SVN for now), and if changes are detected then it can pull the new version and launch build step(s)
(eg. to build different versions of the same code, distribute builds to multiple places, or whatever).  It's basically a replacement for using
batch/shell scripts to manage code updates/builds/distribution, with some built-in features geared specifically for such jobs.

All configuration is done via simple INI files. Each configuration can run multiple builds, and each build can run up to 5 steps, for example: 
I<clean>, I<build>, I<deploy>, I<distribute>, and I<finish>.  It can also be forced to launch builds, regardless of repo status.

Each step can run any system command, for example C<make>, along with any required arguments.  If you can run it from
the command line, then it should work when run via F<SBA>. All steps are optional.

For distribution of build results ("artifacts"), a built-in L<FTP client|/FTP Distribution> can be used to upload files to a server. 

Finally, a notification e-mail can be sent to multiple recipients, including a full log of the job results.

Limitations/TODO: 

=over 4

=item - Only checks the currently checked-out branch of a repo for updates.  Does not detect new branches/tags/etc.

=item - Add Git support.

=back

WARNING: The whole point of this program is to execute system commands (scripts) contained in a configuration file.  As such,
you need to take great care if running configuration files from untrusted sources (like a public code repo). In fact you shouldn't do it, ever!

=head1 SYNOPSIS

See full L</INSTRUCTIONS> below (run C<sba --man> if needed).
 
 - Create a config file, eg. mybuilds.ini.
 - Put it in the same folder as you would normally launch builds from.
 - Run:  sba.pl -c path/to/mybuilds.ini

 Summary: 
 sba.pl -c <config file> [other options]
 
 
=head1 OPTIONS

Note: all options can appear in the configuration file's [settings] block using the same names (long versions) as shown here, minus the "--" part.
See L</INSTRUCTIONS> below for details about config file format.

=over 4

=item B<-c> <file>  I<(default: ./sba.ini)>

Configuration file to use. The path of this file also determines the script's working directory,
which in turn determines the base path for all executed commands (all paths are relative to the working folder).

=item B<--log-folder or -l> [<path>] I<(default: ./log)>

Path for all output logs. F<SBA> generates its own log (same as what you'd see on the console), plus the output of every command
is directed to its own log file (eg. log/build1-clean.log, log/build1-build.log, etc). Absolute path, or relative to working directory. 
You might want to set it to be inside the build directory, as in the provided examples. 

To disable all logging, set this value to blank (eg. C<--log-folder> or C<log-folder => in the config file. 

=item B<--force-build or --force or -f> I<(default: 0 (false))>

Always (re-)build even if no new repo version detected.  This can also be specified per build config (see config file details, below).

=item B<--quiet or -q>

Do not print anything to the console (STDOUT/STDERR).  Output is still printed to log file (if enabled), and sent in a notification (if enabled).

=item B<--debug or -d>

Output extra runtime details.

=item B<--help or -h or -?>

Print usage summary and options.

=item B<--man>

Print full documentation.

=back

=head2 Notification Options 

(Note: all notify-* option names can also be shortened to just the last part after the dash, eg. C<--to> and C<--server>)

=over 4

=item B<--notify-to> <e-mail[,e-mail][,...]>   I<(required for notifcation)>

One or more e-mail addresses separated by commas.  Blank to disable notification.

=item B<--notify-server> <host.name>  I<(required for notifcation)>

Server to use for sending mail. Blank to disable notification.

=item B<--notify-subj> <subject> I<(default: "[SBA] Build")>

Subject prefix.  Status details get appended to this.

=item B<--notify-always> I<(default: 0 (false))>

Whether to send notifcation even if no builds were performed (eg. no updates were detected, and nothing was forced). 
Default is 0 (only notify when something was actually done).

=item B<--notify-from> <sender e-mail> I<(default:> <> I<(null))>

The sender's e-mail address (also where any bounces would go to).

=item B<--notify-user> <username>

=item B<--notify-pass> <password>

Specify if your sever needs authentication.

=item B<--notify-usetls> I<(default: 0 (false))>

Use TLS/SSL for server connection. Default is false.  Enable if it works with your server.

=item B<--notify-port> <port #> I<(default: (blank))>

Optional server port.  Default (blank) selects autmatically based on plain/ssl transport.

=back

=head1 INSTRUCTIONS

F<SBA> uses a configuration file to determine which tasks to perform.  A config file is needed to process any
actual build steps you want. The config can provide a set of default actions to perform for each step, and
specific actions for individual build(s). In addition, all F<SBA> options can be set in the config file, 
which is much easier to manage than the command line parameters.

=head2 Configuration File Details

=head3 Example config file:
 
 
  -----------------------------------------------------------
  [settings]
  # these are SBA program settings, same as command-line options.
  log-folder    = ../build-sba/log
  notify-to     = me@example.com
  notify-server = localhost
  notify-subj   = "My builds status:"
  
  [build-default]
  # default settings for all builds
  dir           = ../build-sba
  clean         = make clean clean-bin $common
  deploy        = 
  distrib       = sba_ftp ftp.myhost.org user pass /nightly $dir/$name/*.hex
  
  # convenience macro to be used in other commands
  common        = BUILD_TYPE=$name BUILD_PATH=$dir
  
  # all other blocks define individual build configurations
  
  [board-6.0]
  build         = make all -j1 $common BOARD_VER=6 BOARD_REV=0
  
  [board-6.0-dimu-1.1]
  name          = board-6.0-dimu
  build         = make all -j1 $common BOARD_VER=6 BOARD_REV=0 DIMU_VER=1.1
  incremental   = 1
  force         = 1
  enable        = 1
  -----------------------------------------------------------


=head3 Structure of a configuration file:

=over 4

=item - Config file (mostly) follows standard L<.ini file format|http://en.wikipedia.org/wiki/INI_file> specifications, with the following caveats:

=over 8

=item - Parameter and variable names are CASE SENSITIVE!

=item - Comments can start with a semicolon or hash mark (; or #).  Comments must start on their own line.

=item - Long lines can be split using a backslash (\) as the last character of the line to be continued, immediately followed by a newline. eg:

  [Section]
  Parameter=this parameter \
    spreads across \
    a few lines

=back

=item - The optional B<[settings]> block describes F<SBA> runtime options.  Any parameter listed in L</OPTIONS> can be used here 
(simply ommit the leading C<--> before the option name).

=item - The optional B<[build-default]> block describes settings which are shared by all build configs.

=item - Each subsequent B<[named-block]> describes a build configuration.  Block names must be unique, and are used as the build name by default.
They are processed in order of their appearance in the .ini file.

=item - Strings may contain embedded references (macros) to other named params, preceded with a $ sign. 
All macros are evaluated when each config is run (vs. when the config file is initially read).  Check the example above to see how the C<$dir> and
C<$name> variables are used (which correspond to the current build directory and build name, respectively).

=item - Any arbitrary variable can be declared and then used as a macro (like C<$common> is used in the example above).  
Typical variable name syntax rules apply (no spaces, etc).  They can appear in any order in the confg 
file (you do not have to declare a variable before using it, as long as it appears somewhere in the config file).

=back

* Note that the config file is also used by F<SBA> to store some data about each build (eg. last built version and date).  Therefore it should be
writeable by the system.  If it isn't, there will be no way to track the last built version, which may trigger a rebuild on each run.
** It is a good idea to keep backups of your INI config files in case anything goes completely awry and corrupts the original config **

=head3 Per-build Config parameters:

These can appear in the [build-default] block or any build [named-block].  Note that the command names (clean/build/etc) are just arbitrary, meaning
you can run any command you want on any step.  There is also one built-in command you can use to distribute files via FTP -- see the
L</FTP Distribution> help topic, below.

Builds are executed in the order in which they appear in the config file.  A failed build should not prevent other builds from executing.

Build commands are run consecutively: clean -> build -> deploy -> distrib -> final. They are dependent on each other, meaning a failed step will halt
any futher processing of that build configuration.

=over 4

=item B<name> I<(default: "[C<block-name>]")>

A unique name for this build.  By default the C<name> is taken from the title of the config [block], but you can set one explicitly as well.

=item B<dir> I<(default: "")>

Root directory for this build.  If specified, the script will make sure it exists (and try to create it if it doesn't) before processing any commands.

=item B<clean> / B<build> / B<deploy> / B<distrib> / B<final> I<(default: "")>

Commands to execute for a package. Commands specified in the [build-default] block will execute for each build, unless
the same command is specified in the build-specific [named-block].  A blank value will disable the command. At least one command 
should be non-blank, otherwise nothing will be done for the build config.

To determine successful execution of a command, it should return a standard system exit code when run. 
Usually this means zero for sucess and anything else for failure.  Almost any common command-line tool will follow this standard.

=item B<incremental> I<(default: 0 (false))>

Set to 1 to skip clean step, 0 to always clean first.

=item B<force> I<(default: 0 (false))>

Set to 1 to always run this config, even if no new version was detected.  This is like the global --force option, but per-configuration.

=item B<enable>	 I<(default: 1)>

Set to 0 to disable this build, 1 to enable.

=back

Some parmeters are written back to the config file after each build by F<SBA> itself, although you could set these manually if you wanted to.
Currently only the C<last_built_ver> has any real significance, the rest are just a log for now.

=over 4

=item B<last_built_ver>

Keeps track of the last version successfully built.  This is whatever string is used to keep track of versions from the VCS system. 
Eg. SVN would typically use the Revision number (eg. from C<svn info>), or for Git it could be the last commit's SHA1 reference 
(eg. from C<git ls-remote . HEAD>).  You could provide a starting value here if you want to avoid rebuilding on the first 
run of your config file.

=item B<last_built_dt>

Date & time of last successful build. 

=item B<last_run_dt>

Date & time of last run of this config. 

=item B<last_run_stat>

Status code from last run/build attempt. Explained:

  0 = unbuilt; 1-5 = started step; 10-50 = finished step; 110-150 = error during step;
  where step: 1=clean; 2=build; 3=deploy; 4=distrib; 5=finish. 
  Eg. 40=finished distrib, or 110=error during clean

=back
 
=head2 FTP Distribution

To use the built-in FTP client to upload files, specify the follwing command for any of the build steps:

C<sba_ftp ftp_server ftp_user ftp_pass dest_folder [bin|asc] [perm_mask] file/pattern [file/pattern] [...]>

Where:

=over 4

=item B<ftp_server>, B<ftp_user>, B<ftp_pass>

Are the server host name, user name, and password, respectively.  
User should have permissions to upload files and, optionally, create directories and modify permissions (chmod).

=item B<dest folder>

Remote folder to upload files into. Relative or absolute, whatever the server will understand.  For now all files must go into the same folder.  
Will attempt to create this folder on remote system if it doesn't exist (and optionaly apply permission mask using chmod, see below).

=item B<bin|asc>

File transfer mode to use, binary or ascii. This parameter is optional.  Default is binary.

=item B<perm_mask>

Numeric permission mask for chmod after file upload or directory creation, if your server requires it (eg. F<754> for public access). 
This parameter is optional. Set to zero, the default, to disable modifying permissions at all.

=item B<file/pattern>

The file(s) to upload, with absolute or relative path (relative is to current working folder).  Can include wildcards, 
as long as the system is able to expand that to a list of files. Separate multiple entries with a space. 
Only files are allowed here, no directories.

=back

 * Note that you could pass a system command for any value by enclosing it in backticks (`...`) which is standard Perl
 way to capture output from the system.  Eg. <ftp pass> = `cat ~/mypass.txt`  to read the contents of mypass.txt in 
 current user's home directory, and then use it as the password parameter value. 
 
 As another example, if the file "myftp" contains three words: 
 
 my.server.org myuser mypass

 Then:        sba_ftp `cat ~/myftp` /dest/folder ./file/to/upload.ext  
 Results in:  sba_ftp my.server.org myuser mypass /dest/folder ./file/to/upload.ext
 

=head2 E-Mail Notifications

To receive a summary or the completed job, use the notify-* options L<described above|/Notification Options> to specify a destination e-mail address (or several, separated by comma) 
and a B<server> to use for sending mail.  The summary includes what is normally displayed on the console when you run C<sba.pl>.  The subject line includes an
overall status and build totals.  By default notices are only sent when something was actually done (build/distributed), although you can override this using
C<--notify-always> or C<notify-always = 1> in the config file.

The simplest scenario is if your server is local or otherwise can authenticate you w/out logging in (eg. IP address).  You can also specify a user/pass
if necessary.  The C<notify-usetls> option provides some extra security, but might not work due to certificate issues with the underlying Perl SSL module.

=head1 REQUIRES

Perl modules:

=over 4

=item L<Config::IniFiles|http://search.cpan.org/search?query=config-inifile>

=item L<Mail::Sender|http://search.cpan.org/~jenda/Mail-Sender/Sender.pm>

=item L<Net::FTP>

=item L<File::Basename>

=item L<Getopt::Long>

=item L<Pod::Usage>

=item L<Data::Dump> (for debug only)

=back

Make sure your B<environment> is prepared for the build jobs (eg. PATH is set properly, C<make> is available, etc).  You may want a wrapper
shell/batch script which first sets up the environment before calling this program.

E-Mail B<notifications> require a mail server capable of relaying the mail (see L</E-Mail Notifications>).

Windows users might need cygwin/msys or some other version of GNU tools in the current PATH.  If you are building software, 
you probably have it already.  

=head1 AUTHOR

 
 Maxim Paperno - MPaperno@WorldDesign.com
 

=head1 Copyright, License, and Disclaimer

Copyright (c) 2014 by Maxim Paperno. All rights reserved.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 

=cut
