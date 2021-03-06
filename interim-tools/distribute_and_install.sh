#!/bin/bash

# This shabby script is supposed to hold us over for Q1 2013 while we spin up persona
# in AWS. During that time this should enable jrgm to do his own staging deploys

# This script assumes you're running it from Mozilla's office network, either
# VPNd into MPT or not

package=$1
train=$2
loadtesttargets=$3

if [ -z "$package" -o -z "$train" ]; then
  echo "$0 PACKAGE TRAIN [LOADTEST MACHINE NUMBERS]"
  echo "$0 browserid train-2013.02.01"
  echo "$0 browserid train-2013.02.01 \"11 12 13 14\""
  echo "$0 browserid train-2013.02.01 ALL"
  echo "$0 browserid-bigtent train-2013.02.01"
  echo "$0 browserid-certifier train-2013.02.01"
  exit 1
fi

if [ "$package" = "browserid" -o "$package" = "browserid_private" ]; then
  rpmname="browserid-server"
else
  rpmname="$package"
fi

if [ "$package" = "browserid-bigtent" -o "$package" = "browserid-certifier" ]; then
  targets="bigtent-yahoo1.idweb bigtent-yahoo2.idweb"
elif [ "$package" = "browserid" ]; then
  SERVERS_web="web1.idweb web2.idweb web3.idweb"
  SERVERS_sweb="sweb1.idsecweb sweb2.idsecweb sweb3.idsecweb"
  SERVERS_sign="sign1.idkeysign sign2.idkeysign sign3.idkeysign"
  SERVERS_all="$SERVERS_web $SERVERS_sweb $SERVERS_sign"
  targets="$SERVERS_all"
fi

if [ -z "$loadtesttargets" ]; then
  loadtesttargets="11 12"
fi

if [ "$loadtesttargets" = "ALL" ]; then
  loadtesttargets="`seq 4 9` `seq 11 30`"
fi

function fetch {
  path="$1"
  remotefile="$2"
  ssh r6.build.mtv1.svc.mozilla.com "
    cat \"$path/$remotefile\"
  " > "$remotefile"
  if [ ! -e "$remotefile" ]; then
    exit 1
  fi
}

function push {
  adm=adm1.scl2.stage.svc.mozilla.com
  jump=boris.mozilla.com
  remotehost=$1
  localfile=$2

  if ssh -o ConnectTimeout=1 $remotehost 'true' >/dev/null; then
    cat < $localfile | ssh $remotehost "
      cat > `basename $localfile`
    "
  elif ssh -o ConnectTimeout=1 $adm 'true' >/dev/null; then
    cat < $localfile | ssh -A $adm "
      ssh $remotehost \"
        cat > `basename $localfile`
      \"
    "
  else
    cat < $localfile | ssh -A $jump "
      ssh -A $adm \"
        ssh $remotehost \\\"
          cat > `basename $localfile`
        \\\"
      \"
    "
  fi
}

function multiscp {
  hostlist=$1
  filename=$2
  tempfiletemplate="/tmp/`basename $0`-XXXXXX"
  pidlistfile="`mktemp $tempfiletemplate`"
  exitstatus=0
  for host in $hostlist; do
    scp $filename $host: &
    echo "$!" >>$pidlistfile
  done
  for pid in `cat $pidlistfile`; do
    if ! wait $pid; then
      let exitstatus++
    fi
  done
  rm $pidlistfile
  return $exitstatus
}

function multissh {
  hostlist=$1
  remotecommand=$2
  tempfiletemplate="/tmp/`basename $0`-XXXXXX"
  pidlistfile="`mktemp $tempfiletemplate`"
  exitstatus=0
  for host in $hostlist; do
    bash -c "ssh $host \"$remotecommand\" 2>&1 | sed -e \"s/^/$host: /\"
      test ${PIPESTATUS[0]} -eq 0 ||
      (echo \"Encountered an error running command on to $host\" && false)" &
    echo "$!" >>$pidlistfile
  done
  for pid in `cat $pidlistfile`; do
    if ! wait $pid; then
      let exitstatus++
    fi
  done
  rm $pidlistfile
  return $exitstatus
}

fullrpmname="`ssh r6.build.mtv1.svc.mozilla.com \"ls -t1 ~/workspace/$package/rpmbuild/RPMS/x86_64/$rpmname-*${train#train-}*.rpm | grep -v debug | head -1\"`"
rpmfilename="`basename $fullrpmname`"
echo "Fetching $rpmfilename"
if ! fetch "`dirname $fullrpmname`" "$rpmfilename"; then
  echo "Unable to fetch $rpmfilename. Aborting..."
  exit 1
fi

echo "Preparing to distribute $rpmfilename"

if [ "$package" = "browserid-bigtent" -o "$package" = "browserid-certifier" -o "$package" = "browserid" ]; then
  echo "Distributing to adm1.scl2.stage.svc.mozilla.com"
  push adm1.scl2.stage.svc.mozilla.com $rpmfilename
fi

if [ "$package" = "browserid" ]; then
  for i in $loadtesttargets; do
    clientlist="$clientlist client${i}.scl2.svc.mozilla.com"
  done

  if ssh -o ConnectTimeout=1 client4.scl2.svc.mozilla.com 'true' >/dev/null; then
    echo "Distributing to clientN QA loadtesting machines"
    multiscp "$clientlist" "$rpmfilename"
  else
    echo "Distributing to adm1.scl2.svc.mozilla.com"
    push adm1.scl2.svc.mozilla.com $rpmfilename
    ssh -A boris.mozilla.com "
      ssh -A adm1.scl2.svc.mozilla.com \"
        xapply -xP25 \\\"scp $rpmfilename %1: 2>&1 | sed -e 's/^/%1: /'; test ${PIPESTATUS[0]} -eq 0\\\" $clientlist
      \"
    "
  fi
fi

# This requires sudo on mrepo
#echo "Distributing to mrepo1.dmz.scl3.mozilla.com"
#push mrepo1.dmz.scl3.mozilla.com $rpmfilename
#ssh -A boris.mozilla.com "ssh mrepo1.dmz.scl3.mozilla.com \"sudo install -m 0644 -o root -g root $rpmname /data/mrepo-src/6Server-x86_64/mozilla-services/ && sudo update-mrepo mozilla-services\""

echo "Starting install to stage"
# /usr/local/bin/install_browserid.sh
# sysadmins r57717

if ssh -o ConnectTimeout=1 adm1.scl2.stage.svc.mozilla.com 'true' >/dev/null; then
  ssh -A adm1.scl2.stage.svc.mozilla.com "
    xapply -P9 \"
      scp $rpmfilename %1: && 
      ssh %1 \\\"test -e $rpmfilename && 
        sudo /usr/local/bin/install_browserid.sh $rpmfilename
      \\\" 2>&1 | sed -e 's/^/%1: /'; test ${PIPESTATUS[0]} -eq 0 ||
      (echo \\\"Encountered an error installing to %1\\\" && false)
    \" $targets
  "
else
  ssh -A boris.mozilla.com "
    ssh -A adm1.scl2.stage.svc.mozilla.com \"
      xapply -P9 \\\"
        scp $rpmfilename %1: && 
        ssh %1 \\\\\\\"test -e $rpmfilename && 
          sudo /usr/local/bin/install_browserid.sh $rpmfilename
        \\\\\\\" 2>&1 | sed -e 's/^/%1: /'; test ${PIPESTATUS[0]} -eq 0 ||
        (echo \\\\\\\"Encountered an error installing to %1\\\\\\\" && false)
      \\\" $targets
    \"
  "
fi

echo "Starting install to QA loadtesting clientN machines"
if [ "$package" = "browserid" ]; then
  if ssh -o ConnectTimeout=1 client4.scl2.svc.mozilla.com 'true' >/dev/null; then
    multissh "$clientlist" "test -e $rpmfilename && 
      sudo /usr/local/bin/install_browserid.sh $rpmfilename"
  else
    ssh -A boris.mozilla.com "
      ssh -A adm1.scl2.svc.mozilla.com \"
        xapply -P25 \\\"
          ssh %1 \\\\\\\"test -e $rpmfilename && 
            sudo /usr/local/bin/install_browserid.sh $rpmfilename
          \\\\\\\" 2>&1 | sed -e 's/^/%1: /'; test ${PIPESTATUS[0]} -eq 0 ||
          (echo \\\\\\\"Encountered an error installing to %1\\\\\\\" && false)
        \\\" $clientlist
      \"
    "
  fi
fi
