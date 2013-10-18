use strict;

use File::Find;

=comment

Copyright (c) 2003-2010, Andrew Dunstan

See accompanying License file for license details

=cut 

##########################################################################
#
# SCM Class and subclasses for specific SCMs (currently CVS and git).
#
#########################################################################

package EximBuild::SCM;

use vars qw($VERSION); $VERSION = 'REL_0.1';

# factory function to return the right subclass
sub new
{
    my $class = shift;
    my $conf = shift;
    my $target = shift || 'exim';
    if (defined($conf->{scm}) &&  $conf->{scm} =~ /^git$/i)
    {
        $conf->{scm} = 'git';
        return new EximBuild::SCM::Git $conf, $target;
    }
    #elsif ((defined($conf->{scm}) &&  $conf->{scm} =~ /^cvs$/i )
    #    ||$conf->{csvrepo}
    #    ||$conf->{cvsmethod})
    #{
    #    $conf->{scm} = 'cvs';
    #    return new EximBuild::SCM::CVS $conf, $target;
    #}
    die "only Git currently supported";
}

# common routine use for copying the source, called by the
# SCM objects (directly, not as class methods)
sub copy_source
{
    my $using_msvc = shift;
    my $target = shift;
    my $build_path = shift;

    # annoyingly, there isn't a standard perl module to do a recursive copy
    # and I don't want to require use of the non-standard File::Copy::Recursive
    system("cp -r $target $build_path 2>&1");
    my $status = $? >> 8;
    die "copying directories: $status" if $status;

}

# required operations in each subclass:
# new()
# copy_source_required()
# copy_source()
# check_access()
# get_build_path()
# checkout()
# cleanup()
# find_changed()
# get_versions()
# log_id()

##################################
#
# SCM for git
#
##################################

package EximBuild::SCM::Git;

use File::Copy;
use Cwd;

sub new
{
    my $class = shift;
    my $conf = shift;
    my $target = shift;
    my $self = {};
    $self->{gitrepo} = $conf->{scmrepo} ||
                       "git://git.exim.org/exim.git";
    $self->{reference} = $conf->{git_reference}
      if defined($conf->{git_reference});
    $self->{mirror} =(
        $target eq 'exim'
        ? "$conf->{build_root}/exim.git"
        :"$conf->{build_root}/$target-exim.git"
    )if $conf->{git_keep_mirror};
    $self->{ignore_mirror_failure} = $conf->{git_ignore_mirror_failure};
    $self->{target} = $target;
    return bless $self, $class;
}

sub copy_source_required
{
    my $self = shift;

    # always copy git
    return 1;
}

sub copy_source
{
    my $self = shift;
    my $using_msvc = shift;
    my $target = $self->{target};
    my $build_path = $self->{build_path};
    die "no build path" unless $build_path;

    # we don't want to copy the (very large) .git directory
    # so we just move it out of the way during the copy
    # there might be better ways of doing this, but this should do for now

    move "$target/.git", "./git-save";
    EximBuild::SCM::copy_source($using_msvc,$target,$build_path);
    move "./git-save","$target/.git";
}

sub get_build_path
{
    my $self = shift;
    my $use_vpath = shift; # irrelevant for git
    my $target = $self->{target};
    $self->{build_path} = "$target.$$";
    return 	$self->{build_path};
}

sub check_access
{

    # no login required?
    return;
}

sub log_id
{
    my $self = shift;
    main::writelog('githead',[$self->{headref}])
      if $self->{headref};
}

sub checkout
{

    my $self = shift;
    my $branch = shift;
    my $gitserver = $self->{gitrepo};
    my $target = $self->{target};
    my $status;

    # Msysgit does some horrible things, especially when it expects a drive
    # spec and doesn't get one.  So we extract it if it exists and use it
    # where necessary.
    my $drive = "";
    my $cwd = getcwd();
    $drive = substr($cwd,0,2) if $cwd =~ /^[A-Z]:/;

    my @gitlog;
    if ($self->{mirror})
    {

        my $mirror = $target eq 'exim' ? 'exim.git' : "$target-exim.git";

        if (-d $self->{mirror})
        {
            @gitlog = `git --git-dir="$self->{mirror}" fetch 2>&1`;
            $status = $self->{ignore_mirror_failure} ? 0 : $? >> 8;
        }
        else
        {
            my $char1 = substr($gitserver,0,1);
            $gitserver = "$drive$gitserver"
              if ( $char1 eq '/' or $char1 eq '\\');

            # this will fail on older git versions
            # workaround is to do this manually in the buildroot:
            #   git clone --bare $gitserver exim.git
            #   (cd exim.git && git remote add --mirror origin $gitserver)
            # or equivalent for other targets
            @gitlog = `git clone --mirror $gitserver $self->{mirror} 2>&1`;
            $status = $? >>8;
        }
        if ($status)
        {
            unshift(@gitlog,"Git mirror failure:\n");
            print @gitlog if ($main::verbose);
            main::send_result('Git-mirror',$status,\@gitlog);
        }
    }

    push @gitlog, "Git arguments:\n".
                  "  branch=$branch gitserver=$gitserver target=$target\n\n";

    if (-d $target)
    {
        chdir $target;
        my @branches = `git branch 2>&1`;
        unless (grep {/^\* bf_$branch$/} @branches)
        {
            chdir '..';
            print "Missing checked out branch bf_$branch:\n",@branches
              if ($main::verbose);
            unshift @branches,"Missing checked out branch bf_$branch:\n";
            main::send_result("$target-Git",$status,\@branches);
        }
        my @pulllog = `git pull 2>&1`;
        push(@gitlog,@pulllog);
        chdir '..';
    }
    else
    {
        my $reference =
          defined($self->{reference}) ?"--reference $self->{reference}" : "";

        my $base = $self->{mirror} || $gitserver;

        my $char1 = substr($base,0,1);
        $base = "$drive$base"
          if ( $char1 eq '/' or $char1 eq '\\');

        my @clonelog = `git clone -q $reference $base $target 2>&1`;
        push(@gitlog,@clonelog);
        $status = $? >>8;
        if (!$status)
        {
            chdir $target;

            # make sure we don't name the new branch HEAD
            # also, safer to checkout origin/master than origin/HEAD, I think
            my $rbranch = $branch eq 'HEAD' ? 'master' : $branch;
            my @colog =
              `git checkout -b bf_$branch --track origin/$rbranch 2>&1`;
            push(@gitlog,@colog);
            chdir "..";
        }
    }
    $status = $? >>8;
    print "================== git log =====================\n",@gitlog
      if ($main::verbose > 1);

    # can't call writelog here because we call cleanlogs after the
    # checkout stage, since we only clear out the logs if we find we need to
    # do a build run.
    # consequence - we don't save the git log if we don't do a run
    # doesn't matter too much because if git fails we exit anyway.

    # Don't call git clean here. If the user has left stuff lying around it
    # might be important to them, so instead of blowing it away just bitch
    # loudly.

    chdir "$target";
    my @gitstat = `git status --porcelain 2>&1`;
    chdir "..";

    my ($headref,$refhandle);
    if (open($refhandle,"$target/.git/refs/heads/bf_$branch"))
    {
        $headref = <$refhandle>;
        chomp $headref;
        close($refhandle);
        $self->{headref} = $headref;
    }

    main::send_result("$target-Git",$status,\@gitlog)	if ($status);
    unless ($main::nosend && $main::nostatus)
    {
        push(@gitlog,"===========",@gitstat);
        main::send_result("$target-Git-Dirty",99,\@gitlog)
          if (@gitstat);
    }

    # if we were successful, however, we return the info so that
    # we can put it in the newly cleaned logdir  later on.
    return \@gitlog;
}

sub cleanup
{
    my $self = shift;
    my $target = $self->{target};
    chdir $target;
    system("git clean -dfxq");
    chdir "..";
}

# private Class level routine for getting changed file data
sub parse_log
{
    my $cmd = shift;
    my @lines = `$cmd`;
    chomp(@lines);
    my $commit;
    my $list = {};
    foreach my $line (@lines)
    {
        next if $line =~ /^(Author:|Date:|\s)/;
        next unless $line;
        if ($line =~ /^commit ([0-9a-zA-Z]+)/)
        {
            $commit = $1;
        }
        else
        {

            # anything else should be a file name
            $line =~ s/\s+$//; # make sure all trailing space is trimmed
            $list->{$line} ||= $commit; # keep most recent commit
        }
    }
    return $list;
}

sub find_changed
{
    my $self = shift;
    my $target = $self->{target};
    my $current_snap = shift;
    my $last_run_snap = shift;
    my $last_success_snap = shift || 0;
    my $changed_files = shift;
    my $changed_since_success = shift;

    my $cmd = qq{git --git-dir=$target/.git log -n 1 "--pretty=format:%ct"};
    $$current_snap = `$cmd` +0;

    # get the list of changed files and stash the commit data

    if ($last_run_snap)
    {
        if ($last_success_snap > 0 && $last_success_snap < $last_run_snap)
        {
            $last_success_snap++;
            my $lrsscmd ="git  --git-dir=$target/.git log --name-only "
              ."--since=$last_success_snap --until=$last_run_snap";
            $self->{changed_since_success} = parse_log($lrsscmd);
        }
        else
        {
            $self->{changed_since_success} = {};
        }
        $last_run_snap++;
        my $lrscmd ="git  --git-dir=$target/.git log --name-only "
          ."--since=$last_run_snap";
        $self->{changed_since_last_run} = parse_log($lrscmd);
        foreach my $file (keys %{$self->{changed_since_last_run}})
        {
            delete $self->{changed_since_success}->{$file};
        }
    }
    else
    {
        $self->{changed_since_last_run} = {};
    }

    @$changed_files = sort keys %{$self->{changed_since_last_run}};
    @$changed_since_success = sort keys %{$self->{changed_since_success}};
}

sub get_versions
{
    my $self = shift;
    my $flist = shift;
    return unless @$flist;
    my @repoversions;

    # for git we have already collected and stashed the info, so we just
    # extract it from the stash.

    foreach my $file (@$flist)
    {
        if (exists $self->{changed_since_last_run}->{$file})
        {
            my $commit = $self->{changed_since_last_run}->{$file};
            push(@repoversions,"$file $commit");
        }
        elsif (exists $self->{changed_since_success}->{$file})
        {
            my $commit = $self->{changed_since_success}->{$file};
            push(@repoversions,"$file $commit");
        }
    }
    @$flist = @repoversions;
}

1;
