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

# Sanitize or set up environment
# 1) Remove because spec.txt generation fails if set
export -n PERL_UNICODE

./run_branches.pl $@
