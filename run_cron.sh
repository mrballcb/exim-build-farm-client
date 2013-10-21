#!/bin/sh

if which dirname >/dev/null; then
  BFDIR=`dirname $0`
elif [ "x${BFDIR}" = "x" ]; then
  echo "Cannot find BuildFarm client directory. Exiting."
  exit 1
fi

cd $BFDIR
# Update the build client if new version available
if which git >/dev/null; then
  git pull >/dev/null
fi

./run_branches.pl $@
