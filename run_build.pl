#!/usr/bin/perl

=comment

Copyright (c) 2003-2010, Andrew Dunstan

See accompanying License file for license details

=cut 

####################################################

=comment

 NAME: run_build.pl - script to run exim buildfarm

 SYNOPSIS:

  run_build.pl [option ...] [branchname]

 AUTHOR: Andrew Dunstan

 DOCUMENTATION:

  See http://wiki.exim.org/wiki/PostgreSQL_Buildfarm_Howto

 REPOSITORY:

  https://github.com/EximBuildFarm/client-code

=cut

###################################################

use vars qw($VERSION); $VERSION = 'REL_0.1';

use strict;
use warnings;
use Config;
use Fcntl qw(:flock :seek);
use File::Path;
use File::Copy;
use File::Basename;
use File::Temp;
use File::Spec;
use IO::Handle;
use POSIX qw(:signal_h strftime);
use Data::Dumper;
use Cwd qw(abs_path getcwd);
use File::Find ();

# save a copy of the original enviroment for reporting
# save it early to reduce the risk of prior mangling
use vars qw($orig_env);

BEGIN
{
    $orig_env = {};
    while (my ($k,$v) = each %ENV)
    {

        # report all the keys but only values for whitelisted settings
        # this is to stop leaking of things like passwords
        $orig_env->{$k} =(
            (
                    $k =~ /^PG(?!PASSWORD)|MAKE|CC|CPP|FLAG|LIBRAR|INCLUDE/
                  ||$k =~/^(HOME|LOGNAME|USER|PATH|SHELL)$/
            )
            ? $v
            : 'xxxxxx'
        );
    }
}

use EximBuild::SCM;
use EximBuild::Options;
use EximBuild::WebTxn;

my %module_hooks;
my $orig_dir = getcwd();
push @INC, $orig_dir;

# make sure we exit nicely on any normal interrupt
# so the cleanup handler gets called.
# that lets us stop the db if it's running and
# remove the inst and exim directories
# so the next run can start clean.

foreach my $sig (qw(INT TERM HUP QUIT))
{
    $SIG{$sig}=\&interrupt_exit;
}

# copy command line before processing - so we can later report it
# unmunged

my @invocation_args = (@ARGV);

# process the command line
EximBuild::Options::fetch_options();

die "only one of --from-source and --from-source-clean allowed"
  if ($from_source && $from_source_clean);

die "only one of --skip-steps and --only-steps allowed"
  if ($skip_steps && $only_steps);

$verbose=1 if (defined($verbose) && $verbose==0);
$verbose ||= 0; # stop complaints about undefined var in numeric comparison

if ($testmode)
{
    $verbose=1 unless $verbose;
    $forcerun = 1;
    $nostatus = 1;
    $nosend = 1;

}

use vars qw(%skip_steps %only_steps);
$skip_steps ||= "";
if ($skip_steps =~ /\S/)
{
    %skip_steps = map {$_ => 1} split(/\s+/,$skip_steps);
}
$only_steps ||= "";
if ($only_steps =~ /\S/)
{
    %only_steps = map {$_ => 1} split(/\s+/,$only_steps);
}

# Currently only specifying a branch is actually used.
# Specifying a different repo is just a wishlist item .
use vars qw($branch $repo);
my ($arg1,$arg2) = (shift,shift);
$branch = $arg2 ? $arg2 :
          $arg1 ? $arg1 :
          'HEAD';
$repo = $arg2 ? $arg1 : 'exim';
my $explicit_branch = $branch;

print_help() if ($help);

#
# process config file
#
require $buildconf;

# get the config data into some local variables
my (
    $buildroot,$target,$animal, $print_success,
    $aux_path,$trigger_exclude,$trigger_include,$secret,
    $keep_errs,$force_every, $make, $optional_steps,
    $use_vpath,$tar_log_cmd, $using_msvc, $extra_config,
    $make_jobs, $core_file_glob
  )
  =@EximBuild::conf{
    qw(build_root target animal print_success aux_path trigger_exclude
      trigger_include secret keep_error_builds force_every make optional_steps
      use_vpath tar_log_cmd using_msvc extra_config make_jobs core_file_glob)
  };

#default is no parallel build
$make_jobs ||= 1;

# default core file pattern is Linux, which used to be hardcoded
$core_file_glob ||= 'core*';

# legacy name
if (defined($EximBuild::conf{trigger_filter}))
{
    $trigger_exclude = $EximBuild::conf{trigger_filter};
}

my  $scm_timeout_secs = $EximBuild::conf{scm_timeout_secs}
  || $EximBuild::conf{cvs_timeout_secs};

print scalar(localtime()),": buildfarm run for $animal:$branch starting\n"
  if $verbose;

if (ref($force_every) eq 'HASH')
{
    $force_every = $force_every->{$branch} || $force_every->{default};
}

my $config_opts = $EximBuild::conf{config_opts};
my $scm = new EximBuild::SCM \%EximBuild::conf;

my $buildport;

if (exists $EximBuild::conf{base_port})
{
    $buildport = $EximBuild::conf{base_port};
    if ($branch =~ /REL(\d+)_(\d+)/)
    {
        $buildport += (10 * ($1 - 7)) + $2;
    }
}
else
{

    # support for legacy config style
    $buildport = $EximBuild::conf{branch_ports}->{$branch} || 5999;
}

$ENV{EXTRA_REGRESS_OPTS} = "--port=$buildport";

$tar_log_cmd ||= "tar -z -cf runlogs.tgz *.log";

my $logdirname = "lastrun-logs";

if ($from_source || $from_source_clean)
{
    $from_source ||= $from_source_clean;
    die "sourceroot $from_source not absolute"
      unless $from_source =~ m!^/!;

    # we need to know where the lock should go, so unless the path
    # contains HEAD we require it to be specified.
    die "must specify branch explicitly with from_source"
      unless ($explicit_branch || $from_source =~ m!/HEAD/!);
    $verbose ||= 1;
    $nosend=1;
    $nostatus=1;
    $use_vpath = undef;
    $logdirname = "fromsource-logs";
}

my @locales;
if ($branch eq 'HEAD' || $branch ge 'REL8_4')
{

    # non-C locales are not regression-safe before 8.4
    @locales = @{$EximBuild::conf{locales}} if exists $EximBuild::conf{locales};
}
unshift(@locales,'C') unless grep {$_ eq "C"} @locales;

# sanity checks
# several people have run into these

if ( `uname -s 2>&1 ` =~ /CYGWIN/i )
{
    my @procs = `ps -ef`;
    die "cygserver not running" unless(grep {/cygserver/} @procs);
}
my $ccachedir;
if ( $ccachedir = $EximBuild::conf{build_env}->{CCACHE_DIR} )
{

    # ccache is smart enough to create what you tell it is the cache dir, but
    # not smart enough to build the whole path. mkpath croaks on error, so
    # we just let it.

    mkpath $ccachedir;
    $ccachedir = abs_path($ccachedir);
}

if ($^V lt v5.8.0)
{
    die "no aux_path in config file" unless $aux_path;
}

die "cannot run as root/Administrator" unless ($using_msvc or $> > 0);

my $devnull = $using_msvc ? "nul" : "/dev/null";

if (!$from_source)
{
    $scm->check_access($using_msvc);
}

my $st_prefix = "$animal.";

my $exim = $from_source  || $scm->get_build_path($use_vpath);

# set environment from config
while (my ($envkey,$envval) = each %{$EximBuild::conf{build_env}})
{
    $ENV{$envkey}=$envval;
}

# change to buildroot for this branch or die
die "no buildroot" unless $buildroot;

unless ($buildroot =~ m!^/!
    or($using_msvc and $buildroot =~ m![a-z]:[/\\]!i ))
{
    die "buildroot $buildroot not absolute";
}

die "$buildroot does not exist or is not a directory" unless -d $buildroot;

chdir $buildroot || die "chdir to $buildroot: $!";

mkdir $branch unless -d $branch;
chdir $branch || die "chdir to $buildroot/$branch";

# rename legacy status files/directories
foreach my $oldfile (glob("last*"))
{
    move $oldfile, "$st_prefix$oldfile";
}

my $branch_root = getcwd();

# make sure we are using GNU make
die "$make is not GNU Make - please fix config file"
  unless check_make();

# set up modules
foreach my $module (@{$EximBuild::conf{modules}})
{

    # fill in the name of the module here, so use double quotes
    # so everything BUT the module name needs to be escaped
    my $str = qq!
         require EximBuild::Modules::$module; 
         EximBuild::Modules::${module}::setup(
              \$buildroot,
              \$branch,
              \\\%EximBuild::conf,
              \$exim);
    !;
    eval $str;

    # make errors fatal
    die $@ if $@;
}

# acquire the lock

my $lockfile;
my $have_lock;

open($lockfile, ">builder.LCK") || die "opening lockfile: $!";

# only one builder at a time allowed per branch
# having another build running is not a failure, and so we do not output
# a failure message under this condition.
if ($from_source)
{
    die "acquiring lock in $buildroot/$branch/builder.LCK"
      unless flock($lockfile,LOCK_EX|LOCK_NB);
}
elsif ( !flock($lockfile,LOCK_EX|LOCK_NB) )
{
    print "Another process holds the lock on "
      ."$buildroot/$branch/builder.LCK. Exiting."
      if ($verbose);
    exit(0);
}

die "$buildroot/$branch has $exim or inst directories!"
  if ((!$from_source && -d $exim) || -d "inst");

# we are OK to run if we get here
$have_lock = 1;

# check if file present for forced run
my $forcefile = $st_prefix . "force-one-run";
if (-e $forcefile)
{
    $forcerun = 1;
    unlink $forcefile;
}

# try to allow core files to be produced.
# another way would be for the calling environment
# to call ulimit. We do this in an eval so failure is
# not fatal.
eval{
    require BSD::Resource;
    BSD::Resource->import();

    # explicit sub calls here. using & keeps compiler happy
    my $coreok = setrlimit(&RLIMIT_CORE,&RLIM_INFINITY,&RLIM_INFINITY);
    die "setrlimit" unless $coreok;
};
warn "failed to unlimit core size: $@" if $@ && $verbose > 1;

# the time we take the snapshot
my $now=time;
my $installdir = "$buildroot/$branch/inst";
my $dbstarted;

my $extraconf;

# cleanup handler for all exits
END
{

    # clean up temp file
    unlink $ENV{TEMP_CONFIG} if $extraconf;

    # if we have the lock we must already be in the build root, so
    # removing things there should be safe.
    # there should only be anything to cleanup if we didn't have
    # success.
    if ( $have_lock && -d "$exim")
    {
        if ($dbstarted)
        {
            chdir $installdir;
            system(qq{"bin/pg_ctl" -D data stop >$devnull 2>&1});
            foreach my $loc (@locales)
            {
                next unless -d "data-$loc";
                system(qq{"bin/pg_ctl" -D "data-$loc" stop >$devnull 2>&1});
            }
            chdir $branch_root;
        }
        if ( !$from_source && $keep_errs)
        {
            print "moving kept error trees\n" if $verbose;
            my $timestr = strftime "%Y-%m-%d_%H-%M-%S", localtime($now);
            unless (move("$exim", "eximkeep.$timestr"))
            {
                print "error renaming '$exim' to 'eximkeep.$timestr': $!";
            }
            if (-d "inst")
            {
                unless(move("inst", "instkeep.$timestr"))
                {
                    print "error renaming 'inst' to 'instkeep.$timestr': $!";
                }
            }
        }
        else
        {
            rmtree("inst") unless $keepall;
            rmtree("$exim") unless ($from_source || $keepall);
        }

        # only keep the cache in cases of success
        rmtree("$ccachedir") if $ccachedir;
    }

    # get the modules to clean up after themselves
    process_module_hooks('cleanup');

    if ($have_lock)
    {
        if ($use_vpath)
        {

            # vpath builds leave some stuff lying around in the
            # source dir, unfortunately. This should clean it up.
            $scm->cleanup();
        }
        close($lockfile);
        unlink("builder.LCK");
    }
}

# Prepend the DEFAULT settings (if any) to any settings for the
# branch. Since we're mangling this, deep clone $extra_config
# so the config object is kept as given. This is done using
# Dumper() because the MSys DTK perl doesn't have Storable. This
# is less efficient but it hardly matters here for this shallow
# structure.

$extra_config = eval Dumper($extra_config);

if ($extra_config &&  $extra_config->{DEFAULT})
{
    if (!exists  $extra_config->{$branch})
    {
        $extra_config->{$branch} = 	$extra_config->{DEFAULT};
    }
    else
    {
        unshift(@{$extra_config->{$branch}}, @{$extra_config->{DEFAULT}});
    }
}

if ($extra_config && $extra_config->{$branch})
{
    my $tmpname;
    ($extraconf,$tmpname) =File::Temp::tempfile(
        'buildfarm-XXXXXX',
        DIR => File::Spec->tmpdir(),
        UNLINK => 1
    );
    die 'no $tmpname!' unless $tmpname;
    $ENV{TEMP_CONFIG} = $tmpname;
    foreach my $line (@{$extra_config->{$branch}})
    {
        print $extraconf "$line\n";
    }
    autoflush $extraconf 1;
}

use vars qw($steps_completed);
$steps_completed = "";

my @changed_files;
my @changed_since_success;
my $last_status;
my $last_run_snap;
my $last_success_snap;
my $current_snap;
my @filtered_files;
my $savescmlog = "";

if ($from_source_clean)
{
    print time_str(),"cleaning source in $exim ...\n";
    clean_from_source();
}
elsif (!$from_source)
{

    # see if we need to run the tests (i.e. if either something has changed or
    # we have gone over the force_every heartbeat time)

    print time_str(),"checking out source ...\n" if $verbose;

    my $timeout_pid;

    $timeout_pid = spawn(\&scm_timeout,$scm_timeout_secs)
      if $scm_timeout_secs;

    $savescmlog = $scm->checkout($branch);
    $steps_completed = "SCM-checkout";

    process_module_hooks('checkout',$savescmlog);

    if ($timeout_pid)
    {

        # don't kill me, I finished in time
        if (kill(SIGTERM, $timeout_pid))
        {

            # reap the zombie
            waitpid($timeout_pid,0);
        }
    }

    print time_str(),"checking if build run needed ...\n" if $verbose;

    # transition to new time processing
    unlink "last.success";

    # get the timestamp data
    $last_status = find_last('status') || 0;
    $last_run_snap = find_last('run.snap');
    $last_success_snap = find_last('success.snap');
    $forcerun = 1 unless (defined($last_run_snap));

    # updated by find_changed to last mtime of any file in the repo
    $current_snap=0;

    # see if we need to force a build
    $last_status = 0
      if ( $last_status
        && $force_every
        &&$last_status+($force_every*3600) < $now);
    $last_status = 0 if $forcerun;

    # see what's changed since the last time we did work
    $scm->find_changed(\$current_snap,$last_run_snap, $last_success_snap,
        \@changed_files,\@changed_since_success);

    #ignore changes to files specified by the trigger exclude filter, if any
    if (defined($trigger_exclude))
    {
        @filtered_files = grep { !m[$trigger_exclude] } @changed_files;
    }
    else
    {
        @filtered_files = @changed_files;
    }

    #ignore changes to files NOT specified by the trigger include filter, if any
    if (defined($trigger_include))
    {
        @filtered_files = grep { m[$trigger_include] } @filtered_files;
    }

    my $modules_need_run;

    process_module_hooks('need-run',\$modules_need_run);

    # if no build required do nothing
    if ($last_status && !@filtered_files && !$modules_need_run)
    {
        print time_str(),
          "No build required: last status = ",scalar(gmtime($last_status)),
          " GMT, current snapshot = ",scalar(gmtime($current_snap))," GMT,",
          " changed files = ",scalar(@filtered_files),"\n"
          if $verbose;
        rmtree("$exim");
        exit 0;
    }

    # get version info on both changed files sets
    # XXX modules support?

    $scm->get_versions(\@changed_files);
    $scm->get_versions(\@changed_since_success);

} # end of unless ($from_source)

cleanlogs();

writelog('SCM-checkout',$savescmlog) unless $from_source;
$scm->log_id() unless $from_source;

# copy/create according to vpath/scm settings

if ($use_vpath)
{
    print time_str(),"creating vpath build dir $exim ...\n" if $verbose;
    mkdir $exim || die "making $exim: $!";
}
elsif (!$from_source && $scm->copy_source_required())
{
    print time_str(),"copying source to $exim ...\n" if $verbose;

    $scm->copy_source($using_msvc);
}

process_module_hooks('setup-target');

# start working

set_last('status',$now) unless $nostatus;
set_last('run.snap',$current_snap) unless $nostatus;

my $started_times = 0;
print time_str(),"running configure ...\n" if $verbose;

# each of these routines will call send_result, which calls exit,
# on any error, so each step depends on success in the previous
# steps.
configure();

make();

display_features();

make_test() if (check_optional_step('make_test'));

make_doc() if (check_optional_step('build_docs'));

##check_port_is_ok($buildport,'Post');

# if we get here everything went fine ...

my $saved_config = get_config_summary();

rmtree("inst"); # only keep failures
rmtree("$exim") unless ($from_source || $keepall);

print(time_str(),"OK\n") if $verbose;

send_result("OK");

exit;

############## end of main program ###########################

sub print_help
{
    print qq!
usage: $0 [options] [branch]

 where options are one or more of:

  --nosend                  = don't send results
  --nostatus                = don't set status files
  --force                   = force a build run (ignore status files)
  --from-source=/path       = use source in path, not from SCM
  or
  --from-source-clean=/path = same as --from-source, run make distclean first
  --config=/path/to/file    = alternative location for config file
  --keepall                 = keep directories if an error occurs
  --verbose[=n]             = verbosity (default 1) 2 or more = huge output.
  --quiet                   = suppress normal error message 
  --test                    = short for --nosend --nostatus --verbose --force
  --skip-steps=list         = skip certain steps
  --only-steps=list         = only do certain steps, not allowed with skip-steps

Default branch is HEAD. Usually only the --config option should be necessary.

!;
    exit(0);
}

sub time_str
{
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    return sprintf("[%.2d:%.2d:%.2d] ",$hour, $min, $sec);
}

sub step_wanted
{
    my $step = shift;
    return $only_steps{$step} if $only_steps;
    return !$skip_steps{$step} if $skip_steps;
    return 1; # default is everything is wanted
}

sub register_module_hooks
{
    my $who = shift;
    my $what = shift;
    while (my ($hook,$func) = each %$what)
    {
        $module_hooks{$hook} ||= [];
        push(@{$module_hooks{$hook}},[$func,$who]);
    }
}

sub process_module_hooks
{
    my $hook = shift;

    # pass remaining args (if any) to module func
    foreach my $module (@{$module_hooks{$hook}})
    {
        my ($func,$module_instance) = @$module;
        &$func($module_instance, @_);
    }
}

sub check_optional_step
{
    my $step = shift;
    my $oconf;
    my $shandle;

    return undef unless ref($oconf = $optional_steps->{$step});
    if ($oconf->{branches})
    {
        return undef unless grep {$_ eq $branch} @{$oconf->{branches}};
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =localtime(time);
    return undef if (exists $oconf->{min_hour} &&  $hour < $oconf->{min_hour});
    return undef if (exists $oconf->{max_hour} &&  $hour > $oconf->{max_hour});
    return undef if (exists $oconf->{dow}
        &&grep {$_ eq $wday} @{$oconf->{dow}});

    my $last_step = $last_status = find_last("$step") || 0;

    return undef unless ($forcerun ||
                         time >$last_step + (3600 * $oconf->{min_hours_since}));
    set_last("$step") unless $nostatus;

    return 1;
}

sub clean_from_source
{
    if (-e "$exim/GNUmakefile")
    {

        # fixme for MSVC
        my @makeout = `cd $exim && $make distclean 2>&1`;
        my $status = $? >>8;
        writelog('distclean',\@makeout);
        print "======== distclean log ===========\n",@makeout if ($verbose > 1);
        send_result('distclean',$status,\@makeout) if $status;
    }
}

sub interrupt_exit
{
    my $signame = shift;
    print "Exiting on signal $signame\n";
    exit(1);
}

sub cleanlogs
{
    my $lrname = $st_prefix . $logdirname;
    rmtree("$lrname");
    mkdir "$lrname" || die "can't make $lrname dir: $!";
}

sub writelog
{
    my $stage = shift;
    my $loglines = shift;
    my $handle;
    my $lrname = $st_prefix . $logdirname;
    open($handle,">$lrname/$stage.log") || die $!;
    print $handle @$loglines;
    close($handle);
}

sub display_features
{
    my @out = `cd $exim
               src/build-*/exim -C test/confs/0000 -bV `;
    my $status = $? >>8;
    writelog('features',\@out);
    print "======== features log ===========\n",@out if ($verbose > 1);
    send_result('Features',$status,\@out) if $status;
    $steps_completed .= " Features";
}
    
sub check_make
{
    my @out = `$make -v 2>&1`;
    return undef unless ($? == 0 && grep {/GNU Make/} @out);
    return 'OK';
}

sub make
{
    return unless step_wanted('make');
    print time_str(),"running make ...\n" if $verbose;
    my $make_args = join(' ',$EximBuild::conf{make_args});
    my (@makeout);
    my $make_cmd = $make;
    $make_cmd = "$make -j $make_jobs"
      if ($make_jobs > 1 && ($branch eq 'HEAD' || $branch ge 'REL9_1'));
    @makeout = `cd $exim/src && $make_cmd $make_args 2>&1`;
    my $status = $? >>8;
    writelog('make',\@makeout);
    print "======== make log ===========\n",@makeout if ($verbose > 1);
    send_result('Make',$status,\@makeout) if $status;
    $steps_completed .= " Make";
}

sub make_doc
{
    return unless step_wanted('make-doc');
    print time_str(),"running make doc ...\n" if $verbose;

    my (@makeout);
    @makeout = `cd $exim/doc/doc-docbook/ && \
                EXIM_VER="4.82" $make everything 2>&1`;
    my $status = $? >>8;
    writelog('make-doc',\@makeout);
    print "======== make doc log ===========\n",@makeout if ($verbose > 1);
    send_result('Doc',$status,\@makeout) if $status;
    $steps_completed .= " Doc";
}

sub get_stack_trace
{
    my $bindir = shift;
    my $pgdata = shift;

    # no core = no result
    my @cores = glob("$pgdata/$core_file_glob");
    return () unless @cores;

    # no gdb = no result
    system "gdb --version > $devnull 2>&1";
    my $status = $? >>8;
    return () if $status;

    my $cmdfile = "./gdbcmd";
    my $handle;
    open($handle, ">$cmdfile");
    print $handle "bt\n";
    close($handle);

    my @trace;

    foreach my $core (@cores)
    {
        my @onetrace = `gdb -x $cmdfile --batch $bindir/exim $core 2>&1`;
        push(@trace,
            "\n\n================== stack trace: $core ==================\n",
            @onetrace);
    }

    unlink $cmdfile;

    return @trace;
}

sub make_install_check
{
    my $locale = shift;
    return unless step_wanted('install-check');
    print time_str(),"running make installcheck ($locale)...\n" if $verbose;

    my @checklog;
    unless ($using_msvc)
    {
        @checklog = `cd $exim/src/test/regress && $make installcheck 2>&1`;
    }
    else
    {
        chdir "$exim/src/tools/msvc";
        @checklog = `perl vcregress.pl installcheck 2>&1`;
        chdir $branch_root;
    }
    my $status = $? >>8;
    my @logfiles =
      ("$exim/src/test/regress/regression.diffs","$installdir/logfile");
    foreach my $logfile(@logfiles)
    {
        next unless (-e $logfile );
        push(@checklog,"\n\n================== $logfile ==================\n");
        my $handle;
        open($handle,$logfile);
        while(<$handle>)
        {
            push(@checklog,$_);
        }
        close($handle);
    }
    if ($status)
    {
        my @trace =
          get_stack_trace("$installdir/bin","$installdir/data-$locale");
        push(@checklog,@trace);
    }
    writelog("install-check-$locale",\@checklog);
    print "======== make installcheck log ===========\n",@checklog
      if ($verbose > 1);
    send_result("InstallCheck-$locale",$status,\@checklog) if $status;
    $steps_completed .= " InstallCheck-$locale";
}

sub make_isolation_check
{
    my $locale = shift;
    return unless step_wanted('isolation-check');
    my @makeout;
    unless ($using_msvc)
    {
        my $cmd =
          "cd $exim/src/test/isolation && $make NO_LOCALE=1 installcheck";
        @makeout = `$cmd 2>&1`;
    }
    else
    {
        chdir "$exim/src/tools/msvc";
        @makeout = `perl vcregress.pl isolationcheck 2>&1`;
        chdir $branch_root;
    }

    my $status = $? >>8;

    # get the log files and the regression diffs
    my @logs = glob("$exim/src/test/isolation/log/*.log");
    push(@logs,"$installdir/logfile");
    unshift(@logs,"$exim/src/test/isolation/regression.diffs")
      if (-e "$exim/src/test/isolation/regression.diffs");
    foreach my $logfile (@logs)
    {
        push(@makeout,"\n\n================== $logfile ===================\n");
        my $handle;
        open($handle,$logfile);
        while(<$handle>)
        {
            push(@makeout,$_);
        }
        close($handle);
    }
    if ($status)
    {
        my @trace =
          get_stack_trace("$installdir/bin","$installdir/data-$locale");
        push(@makeout,@trace);
    }
    writelog('isolation-check',\@makeout);
    print "======== make isolation check logs ===========\n",@makeout
      if ($verbose > 1);

    send_result('IsolationCheck',$status,\@makeout) if $status;
    $steps_completed .= " IsolationCheck";
}

sub make_test
{
    return unless step_wanted('test');
    print time_str(),"running make test ...\n" if $verbose;
    my $tests_range = $EximBuild::conf{range_num_tests} || "1 4";
    my @makeout;
    @makeout =`(cd $exim/test
                autoconf && ./configure && $make )2>&1 `;
    my $status = $? >>8;
    unless($status)
    {
      my @tmp = `(WORKDIR=\$PWD
                  cd $exim/test
                  ./runtest \$WORKDIR/$exim/src/build-*/exim -CONTINUE $tests_range )2>&1`;
      $status = $? >>8;
      push @makeout, @tmp;
    }
    writelog('test',\@makeout);
    print "======== make test logs ===========\n",@makeout
      if ($verbose > 1);

    send_result('Test',$status,\@makeout) if $status;
    $steps_completed .= " Test";
}

sub make_ecpg_check
{
    return unless step_wanted('ecpg-check');
    my @makeout;
    my $ecpg_dir = "$exim/src/interfaces/ecpg";
    if ($using_msvc)
    {
        chdir "$exim/src/tools/msvc";
        @makeout = `perl vcregress.pl ecpgcheck 2>&1`;
        chdir $branch_root;
    }
    else
    {
        @makeout = `cd  $ecpg_dir && $make NO_LOCALE=1 check 2>&1`;
    }
    my $status = $? >>8;

    # get the log files and the regression diffs
    my @logs = glob("$ecpg_dir/test/log/*.log");
    unshift(@logs,"$ecpg_dir/test/regression.diffs")
      if (-e "$ecpg_dir/test/regression.diffs");
    foreach my $logfile (@logs)
    {
        push(@makeout,"\n\n================== $logfile ===================\n");
        my $handle;
        open($handle,$logfile);
        while(<$handle>)
        {
            push(@makeout,$_);
        }
        close($handle);
    }
    if ($status)
    {
        my $base = "$ecpg_dir/test/regress/tmp_check";
        my @trace =
          get_stack_trace("$base/install$installdir/bin",	"$base/data");
        push(@makeout,@trace);
    }
    writelog('ecpg-check',\@makeout);
    print "======== make ecpg check logs ===========\n",@makeout
      if ($verbose > 1);

    send_result('ECPG-Check',$status,\@makeout) if $status;
    $steps_completed .= " ECPG-Check";
}

sub configure
{

    my @quoted_opts;
    foreach my $c_opt (@$config_opts)
    {
        if ($c_opt =~ /['"]/)
        {
            push(@quoted_opts,$c_opt);
        }
        else
        {
            push(@quoted_opts,"'$c_opt'");
        }
    }

    my $env = $EximBuild::conf{makefile_set};
    my $add = $EximBuild::conf{makefile_add};
    my $features = $EximBuild::conf{config_features};

    my $envstr = "";
    while (my ($key,$val) = each %$env)
    {
        $envstr .= "$key='$val'\n";
    }
    while (my ($key,$val) = each %$add)
    {
        $envstr .= "$key+='$val'\n";
    }

    my $conf_path = "src/src/EDITME";
    my $local_conf = "src/Local/Makefile";
    my @confout = `cd $exim; mkdir -p src/Local 2>&1`;
    my @tmp = `cd $exim && cp $conf_path $local_conf 2>&1`;
    my $status = $? >> 8;
    push @confout, @tmp;
    if ($status == 0)
    {
        # First, let's display some directory permissions in case
        # permissions are causing problems.
        my @dir = split('/',`pwd`);
        chomp(@dir);
        my $count = scalar @dir;
        my $loop = 1;
        my $dirs = '';
        while ($loop < $count)
        {
          my $dir = "";
          foreach my $i (0 .. $loop)
          {
            $dir .= $dir[$i].'/';
          }
          $dirs .= " $dir";
          $loop++;
        }
        @tmp = `echo "Verify Directory Permissions"
                ls -ld $dirs`;
        push @confout, @tmp;
        # Build the config file from the EDITME template
        @tmp = `cd $exim && echo '$envstr' >> $local_conf`;
        push @confout, @tmp;
        my $exim_user = $EximBuild::conf{master_exim_user} || 'exim';
        @tmp = `echo "Hardcoded Exim user info:"; id $exim_user
          cd $exim && perl -pi -e 's/^EXIM_USER=.*/EXIM_USER=$exim_user/' $local_conf`;
        push @confout, @tmp;
        my $me = `whoami`; chomp $me;
        @tmp = `echo "Build Farm user info:"; id $me
          cd $exim && perl -pi -e 's/^# CONFIGURE_OWNER=\$/CONFIGURE_OWNER=$me/' $local_conf`;
        push @confout, @tmp;
        @tmp = `cd $exim && perl -pi -e 's/^# TRUSTED_CONFIG_LIST=/TRUSTED_CONFIG_LIST=/' $local_conf`;
        push @confout, @tmp;
        @tmp = `cd $exim && perl -pi -e 's/^# WHITELIST_D_MACROS=.*/WHITELIST_D_MACROS=DIR:EXIM_PATH:AA:ACL:ACLRCPT:ACL_MAIL:ACL_PREDATA:ACL_RCPT:AFFIX:ALLOW:ARG1:ARG2:AUTHF:AUTHS:AUTH_ID_DOMAIN:BAD:BANNER:BB:BR:BRB:CERT:COM:COMMAND_USER:CONNECTCOND:CONTROL:CREQCIP:CREQMAC:CRL:CSS:D6:DATA:DCF:DDF:DEFAULTDWC:DELAY:DETAILS:DRATELIMIT:DYNAMIC_OPTION:ELI:ERROR_DETAILS:ERT:FAKE:FALLBACK:FILTER:FILTER_PREPEND_HOME:FORBID:FORBID_SMTP_CODE:FUSER:HAI:HAP:HARDLIMIT:HEADER_LINE_MAXSIZE:HEADER_MAXSIZE:HELO_MSG:HL:HOSTS:HOSTS_AVOID_TLS:HOSTS_MAX_TRY:HVH:IFACE:IGNORE_QUOTA:INC:INSERT:IP1:IP2:LAST:LDAPSERVERS:LENCHECK:LIMIT:LIST:LOG_SELECTOR:LS:MAXNM:MESSAGE_LOGS:MSIZE:NOTDAEMON:ONCE:ONLY:OPT:OPTION:ORDER:PAH:PEX:PORT:PTBC:QDG:QOLL:QUOTA:QUOTA_FILECOUNT:QWM:RCPT_MSG:REMEMBER:REQUIRE:RETRY:RETRY1:RETRY2:RETURN:RETURN_ERROR_DETAILS:REWRITE:ROUTE_DATA:RRATELIMIT:RT:S:SELECTOR:SELF:SERVER:SERVERS:SREQCIP:SREQMAC:SRV:STD:STRICT:SUB:SUBMISSION_OPTIONS:TIMEOUTDEFER:TIMES:TRUSTED:TRYCLEAR:UL:USE_SENDER:UTF8:VALUE:WMF:X:Y/' $local_conf`;
        push @confout, @tmp;
        @tmp = `cd $exim && perl -pi -e 's/^EXIM_MONITOR=(.*)/# EXIM_MONITOR=\$1/' $local_conf`;
        push @confout, @tmp;
        for my $feature ( @$features )
        {
            @tmp = `cd $exim
                    perl -pi -e '$feature' $local_conf 2>&1
                    echo "Changed feature: $feature" `;
            push @confout, @tmp;
        }
        # Add the final build file to the display output
        @tmp = `cd $exim
                echo
                echo "Contents of Local/Makefile:"
                egrep '^[^#]' $local_conf `;
        push @confout, @tmp;
        # Does not matter what the Exim version is, as long as it is valid.
        my $exim_ver = $EximBuild::conf{exim_test_version} || '4.82';
        `cd $exim
         echo 'EXIM_RELEASE_VERSION="$exim_ver"' > src/src/version.sh
         echo 'EXIM_VARIANT_VERSION=""' >> src/src/version.sh
         echo 'EXIM_COMPILE_NUMBER="0"' >> src/src/version.sh`;
    }
   
    print "======== configure output ===========\n",@confout
      if ($verbose > 1);

    writelog('configure',\@confout);

    if ($status)
    {
        send_result('Configure',$status,\@confout);
    }

    $steps_completed .= " Configure";
}

sub find_last
{
    my $which = shift;
    my $stname = $st_prefix . "last.$which";
    my $handle;
    open($handle,$stname) or return undef;
    my $time = <$handle>;
    close($handle);
    chomp $time;
    return $time + 0;
}

sub set_last
{
    my $which = shift;
    my $stname = $st_prefix . "last.$which";
    my $st_now = shift || time;
    my $handle;
    open($handle,">$stname") or die "opening $stname: $!";
    print $handle "$st_now\n";
    close($handle);
}

sub send_result
{

    # clean up temp file
    $extraconf = undef;

    my $stage = shift;

    my $ts = $now || time;
    my $status=shift || 0;
    my $log = shift || [];
    print "======== log passed to send_result ===========\n",@$log
      if ($verbose > 1);

    unshift(@$log,
        "Last file mtime in snapshot: ",
        scalar(gmtime($current_snap)),
        " GMT\n","===================================================\n")
      unless ($from_source || !$current_snap);

    my $log_data = join("",@$log);
    my $confsum = "";
    my $changed_this_run = "";
    my $changed_since_success = "";
    $changed_this_run = join("!",@changed_files)
      if @changed_files;
    $changed_since_success = join("!",@changed_since_success)
      if ($stage ne 'OK' && @changed_since_success);

    if ($stage eq 'OK')
    {
        $confsum= $saved_config;
    }
    elsif ($stage !~ /CVS|Git|SCM/ )
    {
        $confsum = get_config_summary();
    }
    else
    {
        $confsum = get_script_config_dump();
    }

    my $savedata = Data::Dumper->Dump(
        [
            $changed_this_run, $changed_since_success, $branch, $status,$stage,
            $animal, $ts,$log_data, $confsum, $target, $verbose, $secret
        ],
        [
            qw(changed_this_run changed_since_success branch status stage
              animal ts log_data confsum target verbose secret)
        ]
    );

    my $lrname = $st_prefix . $logdirname;

    # might happen if there is a CVS failure and have never got further
    mkdir $lrname unless -d $lrname;

    my $txfname = "$lrname/web-txn.data";
    my $txdhandle;
    open($txdhandle,">$txfname");
    print $txdhandle $savedata;
    close($txdhandle);

    if ($nosend || $stage eq 'CVS' || $stage eq 'CVS-status' )
    {
        print "Branch: $branch\n";
        if ($stage eq 'OK')
        {
            print "All stages succeeded\n";
            set_last('success.snap',$current_snap) unless $nostatus;
            exit(0);
        }
        else
        {
            print "Stage $stage failed with status $status\n";
            exit(1);
        }
    }

    if ($stage !~ /CVS|Git|SCM|Pre-run-port-check/ )
    {

        my @logfiles = glob("$lrname/*.log");
        my %mtimes = map { $_ => (stat $_)[9] } @logfiles;
        @logfiles =
          map { basename $_ }( sort { $mtimes{$a} <=> $mtimes{$b} } @logfiles );
        my $logfiles = join(' ',@logfiles);
        $tar_log_cmd =~ s/\*\.log/$logfiles/;
        chdir($lrname);
        system("$tar_log_cmd 2>&1 ");
        chdir($branch_root);

    }
    else
    {

        # these would be from an earlier run, since we
        # do cleanlogs() after the cvs stage
        # so don't send them.
        unlink "$lrname/runlogs.tgz";
    }

    my $txstatus;

    # this should now only apply to older Msys installs. All others should
    # be running with perl >= 5.8 since that's required to build exim
    # anyway
    if (!$^V or $^V lt v5.8.0)
    {

        unless (-x "$aux_path/run_web_txn.pl")
        {
            print "Could not locate $aux_path/run_web_txn.pl\n";
            exit(1);
        }

        system("$aux_path/run_web_txn.pl $lrname");
        $txstatus = $? >> 8;
    }
    else
    {
        $txstatus = EximBuild::WebTxn::run_web_txn($lrname) ? 0 : 1;

    }

    if ($txstatus)
    {
        print "Web txn failed with status: $txstatus\n";

        # if the web txn fails, restore the timestamps
        # so we try again the next time.
        set_last('status',$last_status) unless $nostatus;
        set_last('run.snap',$last_run_snap) unless $nostatus;
        exit($txstatus);
    }

    unless ($stage eq 'OK' || $quiet)
    {
        print "BuildFarm member $animal failed on $branch stage $stage\n";
    }

    #	print "Success!\n",$response->content
    #		if $print_success;

    set_last('success.snap',$current_snap) if ($stage eq 'OK' && !$nostatus);

    exit 0;
}

sub get_config_summary
{
    my $handle;
    my $config = "";
    # unless ($using_msvc)
    # {
    #     open($handle,"$exim/config.log") || return undef;
    #     my $start = undef;
    #     while (<$handle>)
    #     {
    #         if (!$start && /created by PostgreSQL configure/)
    #         {
    #             $start=1;
    #             s/It was/This file was/;
    #         }
    #         next unless $start;
    #         last if /Core tests/;
    #         next if /^\#/;
    #         next if /= <?unknown>?/;

    #         # split up long configure line
    #         if (m!\$.*configure.*--with! && length > 70)
    #         {
    #             my $pos = index($_," ",70);
    #             substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
    #             $pos = index($_," ",140);
    #             substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
    #             $pos = index($_," ",210);
    #             substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
    #         }
    #         $config .= $_;
    #     }
    #     close($handle);
    #     $config .=
    #       "\n========================================================\n";
    # }
    $config .= get_script_config_dump();
    return $config;
}

sub get_script_config_dump
{
    my $conf = {
        %EximBuild::conf,  # shallow copy
        script_version => $VERSION,
        invocation_args => \@invocation_args,
        steps_completed => $steps_completed,
        orig_env => $orig_env,
    };
    delete $conf->{secret};
    return  Data::Dumper->Dump([$conf],['Script_Config']);
}

sub scm_timeout
{
    my $wait_time = shift;
    my $who_to_kill = getpgrp(0);
    my $sig = SIGTERM;
    $sig = -$sig;
    print "waiting $wait_time secs to time out process $who_to_kill\n"
      if $verbose;
    foreach my $sig (qw(INT TERM HUP QUIT))
    {
        $SIG{$sig}='DEFAULT';
    }
    sleep($wait_time);
    $SIG{TERM} = 'IGNORE'; # so we don't kill ourself, we're exiting anyway
    # kill the whole process group
    unless (kill $sig,$who_to_kill)
    {
        print "scm timeout kill failed\n";
    }
}

sub spawn
{
    my $coderef = shift;
    my $pid = fork;
    if (defined($pid) && $pid == 0)
    {
        exit &$coderef(@_);
    }
    return $pid;
}

