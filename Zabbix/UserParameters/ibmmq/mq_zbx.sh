#!/bin/bash
# mq_zbx.sh - Zabbix Agent 2 UserParameter helper for IBM MQ. Read-only: dspmq and runmqsc DISPLAY only.
#
#   mq_zbx.sh qmgrs              JSON list of queue managers and their status        (dspmq)
#   mq_zbx.sh queues   <QMGR>    JSON list of local queues: curdepth, maxdepth, dlq   (DISPLAY QLOCAL)
#   mq_zbx.sh channels <QMGR>    JSON list of non-SVRCONN channels and their status   (DISPLAY CHANNEL / CHSTATUS)
#
# Install: copy to /etc/zabbix/scripts/mq_zbx.sh (chmod 0755, owner root) and add userparameter_ibmmq.conf.
# The zabbix user must be allowed to run runmqsc: add it to the "mqm" group (or grant it the +dsp authority
# on the queue manager with setmqaut) and restart the agent so the group is picked up.
#
# Environment (all optional):
#   MQ_INSTALL_PATH  MQ installation, default /opt/mqm (setmqenv is sourced from $MQ_INSTALL_PATH/bin).
#   MQ_ZBX_INCLUDE_SYSTEM=1  also list SYSTEM.* queues. Default: skipped, except the dead letter queue,
#                    which is usually SYSTEM.DEAD.LETTER.QUEUE and must stay in the list.
#
# Failure is loud: when a queue manager is not running or runmqsc fails, the script prints the MQ error to
# stderr and exits 1, so the Zabbix item becomes "not supported" instead of reporting an empty, healthy list.
# Test as the agent user: sudo -u zabbix /etc/zabbix/scripts/mq_zbx.sh queues QM1

set -o pipefail
MQ_INSTALL_PATH="${MQ_INSTALL_PATH:-/opt/mqm}"
# setmqenv -s picks the installation the current shell should use; its output is noise.
# shellcheck disable=SC1091
. "$MQ_INSTALL_PATH/bin/setmqenv" -s >/dev/null 2>&1 || { echo "setmqenv failed under $MQ_INSTALL_PATH" >&2; exit 1; }

die() { echo "$*" >&2; exit 1; }

# mqsc <qmgr> <command> [tolerated-AMQ-code]
# runmqsc exits 10 when a DISPLAY matches nothing. That is an error for the queue and channel lists, but
# DISPLAY CHSTATUS(*) legitimately matches nothing (AMQ8420) when no channel is active, so the caller names it.
mqsc() {
  local out rc
  out=$(echo "$2" | runmqsc "$1" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    if [ -n "$3" ] && [ $rc -eq 10 ] && grep -q "$3" <<<"$out"; then return 0; fi
    die "runmqsc $1 failed (rc=$rc): $(grep -m1 -E '^AMQ[0-9]+' <<<"$out")"
  fi
  printf '%s\n' "$out"
}

case "$1" in
qmgrs)
  out=$(dspmq) || die "dspmq failed"
  [ -n "$out" ] || die "dspmq returned no queue managers"
  awk 'BEGIN{printf "["}
       {match($0,/QMNAME\([^)]*\)/); q=substr($0,RSTART+7,RLENGTH-8)
        match($0,/STATUS\([^)]*\)/); s=substr($0,RSTART+7,RLENGTH-8)
        printf "%s{\"qmgr\":\"%s\",\"status\":\"%s\"}",(n++?",":""),q,s}
       END{print "]"}' <<<"$out";;
queues)
  [ -n "$2" ] || die "usage: $0 queues <QMGR>"
  dlq=$(mqsc "$2" "DISPLAY QMGR DEADQ" | grep -o 'DEADQ([^)]*)' | sed 's/DEADQ(\(.*\))/\1/' | tr -d ' ')
  mqsc "$2" "DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH" | grep -oE 'QUEUE\([^)]*\)|CURDEPTH\([0-9]+\)|MAXDEPTH\([0-9]+\)' | \
  awk -v dlq="$dlq" -v sys="${MQ_ZBX_INCLUDE_SYSTEM:-0}" -F'[()]' '
    BEGIN{printf "["}
    $1=="QUEUE"{q=$2; gsub(/ /,"",q)} $1=="CURDEPTH"{c=$2}
    $1=="MAXDEPTH"{ if (sys!=1 && q ~ /^SYSTEM\./ && q!=dlq) next
      printf "%s{\"queue\":\"%s\",\"curdepth\":%s,\"maxdepth\":%s,\"dlq\":%d}",(n++?",":""),q,c,$2,(q==dlq && q!="")}
    END{print "]"}';;
channels)
  [ -n "$2" ] || die "usage: $0 channels <QMGR>"
  # CHSTATUS lists only channels that are active or have state; a defined channel absent from it is INACTIVE.
  st=$(mqsc "$2" "DISPLAY CHSTATUS(*) STATUS" AMQ8420 | grep -oE 'CHANNEL\([^)]*\)|STATUS\([A-Z]+\)' | paste -d' ' - - | sed -E 's/CHANNEL\((.*)\) STATUS\((.*)\)/\1 \2/')
  mqsc "$2" "DISPLAY CHANNEL(*) CHLTYPE" | grep -oE 'CHANNEL\([^)]*\)|CHLTYPE\([A-Z]+\)' | paste -d' ' - - | sed -E 's/CHANNEL\((.*)\) CHLTYPE\((.*)\)/\1 \2/' | \
  awk -v st="$st" '
    BEGIN{n=split(st,a,"\n"); for(i=1;i<=n;i++){split(a[i],b," "); s[b[1]]=b[2]}; printf "["}
    $2!="SVRCONN" && $1!~/^SYSTEM\./ {x=($1 in s)?s[$1]:"INACTIVE"
      printf "%s{\"channel\":\"%s\",\"type\":\"%s\",\"status\":\"%s\"}",(c++?",":""),$1,$2,x}
    END{print "]"}';;
*) die "usage: $0 qmgrs|queues <QMGR>|channels <QMGR>";;
esac
