
# Package Namespace is hardcoded. Modules must live in
# EximBuild::Modules

package EximBuild::Modules::TestUpgrade;

use EximBuild::Options;
use EximBuild::SCM;

use File::Basename;

use strict;

use vars qw($VERSION); $VERSION = 'REL_0.1';

my $hooks = {

    #    'checkout' => \&checkout,
    #    'setup-target' => \&setup_target,
    #    'need-run' => \&need_run,
    #    'configure' => \&configure,
    #    'build' => \&build,
    #    'install' => \&install,
    'check' => \&check,

    #    'cleanup' => \&cleanup,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of exim that's being built.
    my $conf = shift;  # ref to the whole config object
    my $exim = shift; # exim build dir

    return unless ($branch eq 'HEAD' or $branch ge 'REL9_2');

    die
"overly long build root $buildroot will cause upgrade problems - try something shorter than 46 chars"
      if (length($buildroot) > 46);

    # could even set up several of these (e.g. for different branches)
    my $self  = {
        buildroot => $buildroot,
        eximbranch=> $branch,
        bfconf => $conf,
        exim => $exim
    };
    bless($self, $class);

    # for each instance you create, do:
    main::register_module_hooks($self,$hooks);

}

sub check
{
    my $self = shift;

    return unless main::step_wanted('pg_upgrade-check');

    print main::time_str(), "checking pg_upgrade\n" if	$verbose;

    my $make = $self->{bfconf}->{make};

    local %ENV = %ENV;
    delete $ENV{PGUSER};

    (my $buildport = $ENV{EXTRA_REGRESS_OPTS}) =~ s/--port=//;
    $ENV{PGPORT} = $buildport;

    my @checklog;

    if ($self->{bfconf}->{using_msvc})
    {
        chdir "$self->{exim}/src/tools/msvc";
        @checklog = `perl vcregress.pl upgradecheck 2>&1`;
        chdir "$self->{buildroot}/$self->{eximbranch}";
    }
    else
    {
        my $cmd = "cd $self->{exim}/contrib/pg_upgrade && $make check";
        @checklog = `$cmd 2>&1`;
    }

    my @logfiles = glob("$self->{exim}/contrib/pg_upgrade/*.log");
    foreach my $log (@logfiles)
    {
        my $fname = basename $log;
        local $/ = undef;
        my $handle;
        open($handle,$log);
        my $contents = <$handle>;
        close($handle);
        push(@checklog,
            "=========================== $fname ================\n",$contents);
    }

    my $status = $? >>8;

    main::writelog("check-pg_upgrade",\@checklog);
    print "======== pg_upgrade check log ===========\n",@checklog
      if ($verbose > 1);
    main::send_result("pg_upgradeCheck",$status,\@checklog) if $status;
    {
        no warnings 'once';
        $main::steps_completed .= " pg_upgradeCheck";
    }

}

1;
