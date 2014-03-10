# Simple Build Agent (in Perl)
    

# DESCRIPTION

`SBA` is designed as a very basic "build server" (or [CI](http://en.wikipedia.org/wiki/Continuous_integration), if you prefer).
It can compare a local and remote code repo (SVN for now), and if changes are detected then it can pull the new version and launch build step(s)
(eg. to build different versions of the same code, distribute builds to multiple places, or whatever). It's basically a replacement for using 
batch/shell scripts to manage code updates/builds/distribution, with some built-in features geared specifically for such jobs.

All configuration is done via simple INI files. Each configuration can run multiple builds, and each build can run up to 5 steps, for example: 
_clean_, _build_, _deploy_, _distribute_, and _finish_.  It can also be forced to launch builds, regardless of repo status.

Each step can run any system command, for example `make`, along with any required arguments.  If you can run it from
the command line, then it should work when run via `SBA`. All steps are optional.

A built-in simple ["Zip Archive Utility"](#zip-archive-utility) is included for quick packaging of build results before distribution.

For distribution of build results ("artifacts"), a built-in [FTP client](#ftp-distribution) can be used to upload files to a server. 

Finally, a notification e-mail can be sent to multiple recipients, including a full log of the job results.

Limitations/TODO: 

- - Only checks the currently checked-out branch of a repo for updates.  Does not detect new branches/tags/etc.
- - Add Git support.

WARNING: The whole point of this program is to execute system commands (scripts) contained in a configuration file.  As such,
you need to take great care if running configuration files from untrusted sources (like a public code repo). In fact you shouldn't do it, ever!

# SYNOPSIS

See full ["INSTRUCTIONS"](#instructions) below (run `sba --man` if needed).

    - Create a config file, eg. mybuilds.ini.
    - Put it in the same folder as you would normally launch builds from.
    - Run:  sba.pl -c path/to/mybuilds.ini

    Summary: 
    sba.pl -c <config file> [other options]
    
    

# OPTIONS

Note: all options can appear in the configuration file's \[settings\] block using the same names (long versions) as shown here, minus the "--" part.
See ["INSTRUCTIONS"](#instructions) below for details about config file format.

- __-c__ \<file\>  _(default: ./sba.ini)_

    Configuration file to use. The path of this file also determines the script's working directory,
    which in turn determines the base path for all executed commands (all paths are relative to the working folder).

- __--log-folder__ or __-l__ \[\<path\>\] _(default: ./log)_

    Path for all output logs. `SBA` generates its own log (same as what you'd see on the console), plus the output of every command
    is directed to its own log file (eg. log/build1-clean.log, log/build1-build.log, etc). Absolute path, or relative to working directory. 
    You might want to set it to be inside the build directory, as in the provided examples. 

    To disable all logging, set this value to blank (eg. `--log-folder` or `log-folder =` in the config file. 

- __--force-build__ or __--force__ or __-f__ _(default: 0 (false))_

    Always (re-)build even if no new repo version detected.  This can also be specified per build config (see config file details, below).

- __--quiet__ or __-q__

    Do not print anything to the console (STDOUT/STDERR).  Output is still printed to log file (if enabled), and sent in a notification (if enabled).

- __--debug__ or __-d__

    Output extra runtime details.

- __--help__ or __-h__ or __-?__

    Print usage summary and options.

- __--man__

    Print full documentation.

## Notification Options 

(Note: all notify-\* option names can also be shortened to just the last part after the dash, eg. `--to` and `--server`)

- __--notify-to__ \<e-mail\[,e-mail\]\[,...\]\>   _(required for notifcation)_

    One or more e-mail addresses separated by commas.  Blank to disable notification.

- __--notify-server__ \<host.name\>  _(required for notifcation)_

    Server to use for sending mail. Blank to disable notification.

- __--notify-subj__ \<subject\> _(default: "\[SBA\] Build")_

    Subject prefix.  Status details get appended to this.

- __--notify-always__ _(default: 0 (false))_

    Whether to send notifcation even if no builds were performed (eg. no updates were detected, and nothing was forced). 
    Default is 0 (only notify when something was actually done).

- __--notify-from__ \<sender e-mail\> _(default: first address in `notify-to`)_

    The sender's e-mail address (also where any bounces would go to).  Defaults to the first address found in `notify-to` option.

- __--notify-user__ \<username\>
- __--notify-pass__ \<password\>

    Specify if your sever needs authentication.

- __--notify-usetls__ _(default: 0 (false))_

    Use TLS/SSL for server connection. Default is false.  Enable if it works with your server.

- __--notify-port__ \<port #\> _(default: (blank))_

    Optional server port.  Default (blank) selects autmatically based on plain/ssl transport.

# INSTRUCTIONS

`SBA` uses a configuration file to determine which tasks to perform.  A config file is needed to process any
actual build steps you want. The config can provide a set of default actions to perform for each step, and
specific actions for individual build(s). In addition, all `SBA` options can be set in the config file, 
which is much easier to manage than the command line parameters.

## Configuration File Details

### Example config file:

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

### Structure of a configuration file:

- - Config file (mostly) follows standard [.ini file format](http://en.wikipedia.org/wiki/INI_file) specifications, with the following caveats:
    - - Parameter and variable names are CASE SENSITIVE!
    - - Comments can start with a semicolon or hash mark (; or #).  Comments must start on their own line.
    - - Long lines can be split using a backslash (\\) as the last character of the line to be continued, immediately followed by a newline. eg:

            [Section]
            Parameter=this parameter \
              spreads across \
              a few lines
- - The optional __\[settings\]__ block describes `SBA` runtime options.  Any parameter listed in ["OPTIONS"](#options) can be used here 
(simply ommit the leading `--` before the option name).
- - The optional __\[build-default\]__ block describes settings which are shared by all build configs.
- - Each subsequent __\[named-block\]__ describes a build configuration.  Block names must be unique, and are used as the build name by default.
They are processed in order of their appearance in the .ini file.
- - Strings may contain embedded references (macros) to other named params, preceded with a $ sign. 
All macros are evaluated when each config is run (vs. when the config file is initially read).  Check the example above to see how the `$dir` and
`$name` variables are used (which correspond to the current build directory and build name, respectively).
- - Any arbitrary variable can be declared and then used as a macro (like `$common` is used in the example above).  
Typical variable name syntax rules apply (no spaces, etc).  They can appear in any order in the confg 
file (you do not have to declare a variable before using it, as long as it appears somewhere in the config file).

\* Note that the config file is also used by `SBA` to store some data about each build (eg. last built version and date).  Therefore it should be
writeable by the system.  If it isn't, there will be no way to track the last built version, which may trigger a rebuild on each run.
\*\* It is a good idea to keep backups of your INI config files in case anything goes completely awry and corrupts the original config \*\*

### Per-build Config parameters:

These can appear in the \[build-default\] block or any build \[named-block\].  Note that the command names (clean/build/etc) are just arbitrary, meaning
you can run any command you want on any step. The actual commands are simply passed to your system shell to execute, so they can be anything.  
There are also some built-in command you can use -- see ["FTP Distribution"](#ftp-distribution) and ["Zip Archive Utility"](#zip-archive-utility), below.

Builds are executed in the order in which they appear in the config file.  A failed build should not prevent other builds from executing.

Build commands are run consecutively: clean -\> build -\> deploy -\> distrib -\> final. They are dependent on each other, meaning a failed step will halt
any futher processing of that build configuration.

- __name__ _(default: "\[`block-name`\]")_

    A unique name for this build.  By default the `name` is taken from the title of the config \[block\], but you can set one explicitly as well.

- __dir__ _(default: "")_

    Root directory for this build.  If specified, the script will make sure it exists (and try to create it if it doesn't) before processing any commands.

- __clean__ / __build__ / __deploy__ / __distrib__ / __final__ _(default: "")_

    Commands to execute for a package. Commands specified in the \[build-default\] block will execute for each build, unless
    the same command is specified in the build-specific \[named-block\].  A blank value will disable the command. At least one command 
    should be non-blank, otherwise nothing will be done for the build config.

    To determine successful execution of a command, it should return a standard system exit code when run. 
    Usually this means zero for sucess and anything else for failure.  Almost any common command-line tool will follow this standard.

    There are also some built-in command you can use -- see ["FTP Distribution"](#ftp-distribution) and ["Zip Archive Utility"](#zip-archive-utility), below.

- __incremental__ _(default: 0 (false))_

    Set to 1 to skip clean step, 0 to always clean first.

- __force__ _(default: 0 (false))_

    Set to 1 to always run this config, even if no new version was detected.  This is like the global --force option, but per-configuration.

- __enable__	 _(default: 1)_

    Set to 0 to disable this build, 1 to enable.

Some parmeters are written back to the config file after each build by `SBA` itself, although you could set these manually if you wanted to.
Currently only the `last_built_ver` has any real significance, the rest are just a log for now.

- __last\_built\_ver__

    Keeps track of the last version successfully built.  This is whatever string is used to keep track of versions from the VCS system. 
    Eg. SVN would typically use the Revision number (eg. from `svn info`), or for Git it could be the last commit's SHA1 reference 
    (eg. from `git ls-remote . HEAD`).  You could provide a starting value here if you want to avoid rebuilding on the first 
    run of your config file.

- __last\_built\_dt__

    Date & time of last successful build. 

- __last\_run\_dt__

    Date & time of last run of this config. 

- __last\_run\_stat__

    Status code from last run/build attempt. Explained:

        0 = unbuilt; 1-5 = started step; 10-50 = finished step; 110-150 = error during step;
        where step: 1=clean; 2=build; 3=deploy; 4=distrib; 5=finish. 
        Eg. 40=finished distrib, or 110=error during clean

## FTP Distribution

To use the built-in FTP client to upload files, specify the follwing command for any of the build steps:

`sba_ftp ftp_server ftp_user ftp_pass dest_folder [bin|asc] [perm_mask] file/pattern [file/pattern] [...]`

Where:

- __ftp\_server__, __ftp\_user__, __ftp\_pass__

    Are the server host name, user name, and password, respectively.  
    User should have permissions to upload files and, optionally, create directories and modify permissions (chmod).

- __dest folder__

    Remote folder to upload files into. Relative or absolute, whatever the server will understand.  For now all files must go into the same folder.  
    Will attempt to create this folder on remote system if it doesn't exist (and optionaly apply permission mask using chmod, see below).

- __bin|asc__

    File transfer mode to use, binary or ascii. This parameter is optional.  Default is binary.

- __perm\_mask__

    Numeric permission mask for chmod after file upload or directory creation, if your server requires it (eg. `754` for public access). 
    This parameter is optional. Set to zero, the default, to disable modifying permissions at all.

- __file/pattern__

    The file(s) to upload, with absolute or relative path (relative is to current working folder).  Can include wildcards, 
    as long as the system is able to expand that to a list of files. Separate multiple entries with a space. 
    Only files are allowed here, no directories.

    * Note that you could pass a system command for any value by enclosing it in backticks (`...`) which is standard Perl
    way to capture output from the system.  Eg. <ftp pass> = `cat ~/mypass.txt`  to read the contents of mypass.txt in 
    current user's home directory, and then use it as the password parameter value. 
    
    As another example, if the file "myftp" contains three words: 
    
    my.server.org myuser mypass

    Then:        sba_ftp `cat ~/myftp` /dest/folder ./file/to/upload.ext  
    Results in:  sba_ftp my.server.org myuser mypass /dest/folder ./file/to/upload.ext
    

## Zip Archive Utility

The built-in zip archive creator is very simple (and simplistic).  To use it, specify this for a build step's command:

`sba_zip [-o archive-name.zip] file/dir [file/dir] [...]`

Where:

- __-o__ \<path/and/archive/name.zip\>

    Optionally, specify the resulting archive name and location, with absolute or relative path (relative is to current working folder).
    By default, the archive is named as the first added entry (file or folder name) plus ".zip" apppended, and placed in the same directory.
    For example, if you use this command:

    `sba_zip path/to/binfile.exe`

    The resulting archive will be `path/to/binfile.exe.zip` .  If a wildcard is used, then the first actual resolved name becomes the archive's
    base name.  For example:

    `sba_zip path/to/*.exe`

    Assuming that folder contains `binfile-a.exe` and `binfile-z.exe` exists in that folder, the resulting archive will be `path/to/binfile-a.exe.zip`.

- __file/dir__

    The file(s) of folder(s) to include in the archive, with absolute or relative path (relative is to current working folder).  
    Can include wildcards, as long as the system is able to expand that to a list of files. Separate multiple entries with a space. 

## E-Mail Notifications

To receive a summary or the completed job, use the notify-\* options [described above](#notification-options) to specify a destination e-mail address (or several, separated by comma) 
and a __server__ to use for sending mail.  The summary includes what is normally displayed on the console when you run `sba.pl`.  The subject line includes an
overall status and build totals.  By default notices are only sent when something was actually done (build/distributed), although you can override this using
`--notify-always` or `notify-always = 1` in the config file.

The simplest scenario is if your server is local or otherwise can authenticate you w/out logging in (eg. IP address).  You can also specify a user/pass
if necessary.  The `notify-usetls` option provides some extra security, but might not work due to certificate issues with the underlying Perl SSL module.

# REQUIRES

Perl modules (most are standard:

- [Config::IniFiles](http://search.cpan.org/search?query=config-inifile)
- [Mail::Sender](http://search.cpan.org/~jenda/Mail-Sender/Sender.pm)
- [Net::FTP](http://search.cpan.org/search?query=net-ftp)
- [Archive::Zip](http://search.cpan.org/search?query=archive-zip)
- [Getopt::Long](http://search.cpan.org/search?query=getopt-long)
- [Pod::Usage](http://search.cpan.org/search?query=pod-usage)
- [Data::Dump](http://search.cpan.org/search?query=data-dump) (for debug only)

Make sure your __environment__ is prepared for the build jobs (eg. PATH is set properly, `make` is available, etc).  You may want a wrapper
shell/batch script which first sets up the environment before calling this program.

E-Mail __notifications__ require a mail server capable of relaying the mail (see ["E-Mail Notifications"](#e-mail-notifications)).

Windows users might need cygwin/msys or some other version of GNU tools in the current PATH.  If you are building software, 
you probably have it already.  

# AUTHOR

    Maxim Paperno - MPaperno@WorldDesign.com
    

# Copyright, License, and Disclaimer

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
    
