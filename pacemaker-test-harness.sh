#!/bin/bash
set -o pipefail
test="$1"
verb="$2"
logdir=/root/pcs
log=$logdir/${test}-from-`hostname`-`date '+%Y-%m-%d-%H-%M'`.log

fnFail() {
        echo "Error: $1"
        exit 1
}
# Import the settings of the cluster:
. ./pacemaker-cluster-settings

outagetime="$3"
if [ "x$test" = x ]; then
  echo "Usage:"
  echo "./$0 TEST VERB [ Outage moment date +%s output timestamp ]"
  echo "Verbs: trigger verify restore all"
  echo "Examples:"
  echo "./$0 10-ab trigger"
  echo "./$0 10-ab verify 1787873661"
  exit 0
fi
a=$hosts[0]
b=$hosts[1]
c=$hosts[2]
d=$hosts[3]

fnStandby() {
  case verb in
    verify|restore) return;;
    *)              pcs node standby $1
                    outagetime=`date +%s` ; echo "Outage time: `date +%s`"
                    ;;
  esac
}
fnUnstandby() {
  case verb in
    verify|restore) return;;
    *)              pcs node unstandby $1
                    ;;
  esac
}
fnDropNetwork() {
  case verb in
    verify|restore) return;;
    *)              nmcli networking off
                    outagetime=`date +%s` ; echo "Outage time: `date +%s`"
                    ;;
  esac
}
fnRestart() {
  case verb in
    trigger|verify) return;;
    *)              echo "fence_vmware_rest -a <vcenter> -l <user> -p <password> -n $1 -o off"
                    echo "fence_vmware_rest -a <vcenter> -l <user> -p <password> -n $1 -o on"
                    ;;
  esac
}
fnBlackHoleRoute() {
  case verb in
    verify|restore) return;;
    *)              ip=`getent ahostsv4 $1|awk '{print $1}'`
                    ip route add blackhole $ip
                    outagetime=`date +%s` ; echo "Outage time: `date +%s`"
                    ;;
  esac
}
fnVerifyServiceOn() {

}
fnVerify {
  # Enable artifact collection:
  exec 3>>$log
  BASH_XTRACEFD=3
  set -x
  testresult=0
  for i in "${!hosts[@]}"; do
    echo "Verifying host ${hosts[$i]}"
    case `echo ${1}|cut -c $i` in
      .)  pcs status nodes | grep ${hosts[$i]} |grep Standby || testresult=210
          ;;
      :)  pcs status nodes | grep ${hosts[$i]} |grep Online || testresult=220
          ;;
      _)  pcs status nodes | grep ${hosts[$i]} |grep Offline || testresult=230
          # echo "fence_vmware_rest -a <vCenter-IP> -l <vCenter-username> -p '<vCenter-password>' --ssl-insecure -z -o status -n ${hosts[$i]}"a
          # placeholder:
          echo ON |grep ON && testresult=$((testresult + 5))
          ;;
      +)
          # Is the service up? If nothing is stopped. We do this first to get the the RTO timestamp as early as possible.
          pcs status resources | grep Stopped && testresult=10 || uptimestamp=`date +%s`
          # Just in case some weird reason makes pcs unrunnable or no resources to show as Started at all, an extra test:
          pcs status resources && grep Started || testresult 50
          # If everything is still ok, test result is still zero.
          # Verify:
          # No resources should be running on other non-+ nodes. Check where they are running, register fault if on other nodes
          for node in ${hosts[$i]}; do
            [ "x$node" = `hostname` ] && continue
            pcs status resources |grep $node && testresult=$((testresult + $i))
          done
    esac
  done
  # Compare uptimestamp to outagetime to calculate RTO:
  delta=$((uptimestamp - outagetime))
  if (( $delta <= $rto )); then
      echo "Outage at `date -d @$outagetime` and recovery at `date -d @$uptimestamp` is $delta seconds and meanis we're within RTO of $rto seconds"
  else
      echo "Outage at `date -d @$outagetime` and recovery at `date -d @$uptimestamp` is $delta and means we exceeded RTO of $rto seconds"
      testresult=$((testresult + 100))
  fi
  echo "Final test result is $testresult"
  # Disable artifact collection:
  set +x
  unset BASH_XTRACEFD
  exec 3>&-
  return $testresult
}

# Each verification specifies the expected shape of the cluster using 4 characters
# To represent the state of each node
# _ for expected Offline (off or non-reachable) node
# . for node in Standby
# : for Online but not running resources
# + for Online and running all resources. Current implementation assumes all resources are running on same node.
# Expected resources are provided via array in the pacemaker-cluster-settings config file
# So:
# "+:__" tells fnVerify:
# it should test the first node to be Online running all the resources (+)
# it should test the second node to just be Online (:)
# it should verify that the third and fourth nodes are shut down (_)

case "${test}--`hostname`" in
  10-ab--*)    fnStandby $a ; fnVerify ".+::" ; fnUnstandby $a;;
  11-ba--*)    fnStandby $b ; fnVerify "+.::" ; fnUnstandby $b;;
  12-ab-c--*)  fnStandby $a ; fnStandy $b ; fnVerify "..+:" ; fnUnstandby $a ; fnUnstandby $b;;
  13-cd--*)    fnStandby $c ; fnVerify "::.+" ; fnUnstandby $c;;
  14-dc--*)    fnStandby $d ; fnVerify "::+." ; fnUnstandby $d;;
  15-cd-a--*)  fnStandby $c ; fnStandy $d ; fnVerify "+:.." ; fnUnstandby $c ; fnUnstandby $d;;

  20-ab--$a)    fnDropNetwork $a;;
  20-ab--$b)    fnVerify "_+::" ; fnRestart $a;;

  21-ba--$b)    fnDropNetwork $b;;
  21-ba--$a)    fnVerify "+_::" ; fnRestart $b;;

  30-ab-c--$a)  fnStandby $b ; fnDropNetwork $a;;
  30-ab-c--$c)  fnVerify "_.+:" ; fnUnstandby $b ; fnRestart $a;;

  40-cd--$c)    fnDropNetwork $c;;
  40-cd--$d)    fnVerify "::_+" ; fnRestart $d;;

  41-dc--$d)    fnDropNetwork $d;;
  41-dc--$c)    fnVerify "::+_" ; fnRestart $d;;

  50-cd-a--$c)  fnStandby $d ; fnDropNetwork $c;;
  50-cd-a--$a)  fnVerify "+:_." ; fnUnstandby $d ; fnRestart $c;;

  60-ab-cd--$a) fnRouteDisable $c ; fnRouteDisable $d;;
  60-ab-cd--$b) fnRouteDisable $c ; fnRouteDisable $d;;
  60-ab-cd--$c) fnVerify "+:__" ; fnRestart $c ; fnRestart $d;;

  61-ab-cd--$a) fnRouteDisable $c ; fnRouteDisable $d ; fnRouteDisable $esxcd ; fnVerify ;;
  61-ab-cd--$b) fnRouteDisable $c ; fnRouteDisable $d ; fnVerify ;;
  61-ab-cd--$c) fnVerify "+:.." ; fnRestart $c ; fnRestart $d;;
esac
