#!/bin/bash
fnFail() {
  echo "$1"
  exit 999
}
# Monitor externally with:
# watch -n1 'v=myvg; vgs -o +lv_active $v ; echo ; lvscan|grep $v ; echo ; pvs|grep $v ; lvs $v -ao lv_name,lv_attr,segtype,devices,copy_percent ; mount|grep $v'

testfile=storage_testing_temp_file
restore_rc=0
testresult=0
fnEnsureFlakeyDeviceAndRule() {
  device=${1}
  # Just in case:
  modprobe dm-flakey || fnFail "Could not bring up the dm-flakey driver"
  # start-sector:    Starting sector of the device-mapper range.
  # length:          Number of 512-byte sectors covered by this mapping.
  # target:          The device-mapper target; here, flakey simulates unreliable storage.
  # dev/offset:      Backing device and sector offset; /dev/sdb1, starting at sector 0.
  # up/down:         Duration in seconds the device is healthy  returns I/O errors.

  # Define the physical device to work with:
  physical_device=/dev/$device
  physical_device_offset=0
  physical="$physical_device $physical_device_offset"
  echo "Physical device $physical_device will be used from offset $physical_device_offset"

  # Define the virtual device:
  virtual_device_range_start=0
  virtual_device_range_length=$(blockdev --getsz "$physical_device")
  virtual_device_name="$device.flakey"
  virtual_device="/dev/mapper/${virtual_device_name}"
  virtual_device_target="flakey" # Which "target" (eg "driver" dm should use)
  virtual="$virtual_device_range_start $virtual_device_range_length $virtual_device_target"
  echo "Logical $virtual_device_target dm device $virtual_device_name will be created covering a range starting offset ${virtual_device_range_start}, $virtual_device_range_length sectors long"

  # Define the cycle:
  case "${2}" in
    ioerror)  echo "Making the device produce errors"
              cycle_returns_healthy_this_many_seconds=0 # 0 seconds spent being ok
              cycle_returns_ioerror_this_many_seconds=1 # 1 second sepent being not ok
              cycle_failure_policy="1 error_writes"
              ;;
    corruption)  echo "Making the device produce silent corruption"
              cycle_returns_healthy_this_many_seconds=0 # 0 seconds spent being ok
              cycle_returns_ioerror_this_many_seconds=1 # 1 second sepent being not ok
              cycle_failure_policy="1 drop_writes"
              ;;
    healthy)  echo "Making the device healthy"
              cycle_returns_healthy_this_many_seconds=1
              cycle_returns_ioerror_this_many_seconds=0
              cycle_failure_policy=""
              ;;
    *)        fnFail "Unexpected inputs passed: $@"
              ;;
  esac
  echo "Each flakey i/o cycle will be $cycle_returns_healthy_this_many_seconds seconds ok, and $cycle_returns_ioerror_this_many_seconds seconds using dm_flakey feature $cycle_failure_policy to simulate being not ok"
  cycle="$cycle_returns_healthy_this_many_seconds $cycle_returns_ioerror_this_many_seconds $cycle_failure_policy"
  table="$virtual $physical $cycle"
  echo "Using table string: $table"

  if [ ! -e "$virtual_device" ]; then
    # First time, huh?
    dmsetup create "$virtual_device_name" --table "$table" || fnFail "FAILED: dmsetup create $virtual_device_name --table $table"
  else
    # Replacing existing rule:
    dmsetup reload "$virtual_device_name" --table "$table" || fnFail "FAILED: dmsetup reload $virtual_device_name --table $table"
    dmsetup resume "$virtual_device_name" ||fnFail "FAILED: dmsetup resume $virtual_device_name"
  fi
  if [ "x${2}" = "xhealthy" ]; then
    # If we're not asking flakey to be pumping out errors, the blocks from the flakey device and the raw device should match.
    # Verify by comparing a checksum of four blocks from the raw device and from the flakey device
    # LVM PV label should be at sector 1, i.e. byte offset 512
    sum_real_device=$(dd if=${physical_device} bs=512 skip=1 count=4 2>/dev/null | sha256sum)
    sum_shim_device=$(dd if=${virtual_device} bs=512 skip=1 count=4 2>/dev/null | sha256sum)
    echo "Real device pv block checksum:        $sum_real_device"
    echo "Flakey shim device pv block checksum: $sum_shim_device"
    [ "x$sum_real_device" != "x$sum_shim_device" ] && fnFail "Flakey shim and backing device produce mismatching bloks"
  fi
  echo "Flakey shim device configuration successful. Flakey shim and backing devices:"
  ls -l "${virtual_device}" "${physical_device}"
  echo "Flakey table:"
  dmsetup table /dev/mapper/*.flakey
}
fnDisplayLvmState()
{
  echo "Checking LVM state:"
  [ "x$1" != "x" ] && vg="$1" && pvstring="--select vg_name=$vg"
  echo "LVM Physical volumes:"
  pvs $pvstring
  echo "LVM Volume groups:"
  vgs $vg -o +lv_active
  echo "LVM Logical volumes:"
  lvscan
  lvs -a -o lv_name,lv_attr,segtype,copy_percent,health_status,devices ${vg}

  echo "Volumes healthy"
}
fnListRaidLvs() {
  # Use xargs to strip leading spaces:
  for lv in $(lvs -S 'segtype = raid1' -o lv_name ${vg} --noheadings 2>/dev/null|xargs); do
     dir=/mnt # replace with cib query
     printf "${lv}:${dir} "
  done
}
fnCheckLvmVgGActive() {
  # While active is tracked at lv level (seen in lvscan command)
  # We check if the vg is active using the lv_active field in the vgs output, to get a vg-wide view:
  # Expecting output that looks like this:
  # vgchange -ay myvg
  #   1 logical volume(s) in volume group "myvg" now active
  # vgs myvg -o name,lv_active --noheadings
  #   myvg active
  # vgchange -an myvg
  #   0 logical volume(s) in volume group "myvg" now active
  # vgs myvg -o name,lv_active --noheadings
  #   myvg
  if vgs ${1} -o name,lv_active --noheadings |grep -q active; then
    echo "Volume group ${1} active" && return 0
  else
    echo "Volume group ${1} inactive" && return 1
  fi
}
fnCheckLvmVgVolumesHealthy() {
  vg=${1}
  # Testing lvs ${vg} -o vg_name,name,copy_percent,health_status --noheadings
  # Good/Healthy volume will say:
  # myvg   mylv   100.00
  #
  # Syncing/rebuilding state will say: (we will not proceed in this case)
  # myvg   mylv   45.20
  #
  # Partial/hardware fault will say: (we will not proceed in this case)
  # myvg   mylv   100.00   partial
  lvs_output=$(lvs "${vg}" -o vg_name,name,copy_percent,health_status --noheadings)
  # Use to debug:
  # lvs_output="myvg   mylv   100.00"
  # lvs_output="myvg   mylv   45.20"
  # lvs_output="myvg   mylv   100.00   partial"

  unsynced_volumes=$(echo "$lvs_output"|awk '$3 != "100.00" {print $2 " (" $3 "%)"}')
  [ "x$unsynced_volumes" != "x" ] && echo "$unsynced_volumes" && echo "volumes syncing, returning 1" && return 1

  problem_volumes=$(echo "$lvs_output"|awk '$4 != "" {print $2 " Status: [" $4 "]"}')
  [ "x$problem_volumes" != "x" ] && echo "$problem_volumes" && echo "volumes not healthy, returning 2" && return 2

  echo "Volumes healthy"
}
fnColdSwap() {
  echo
  echo "==> START fnColdSwap called with $@"
  vg=${1}
  old=${2}
  new=${3}
  [ ! -e $old ] && fnFail "Unexpected state, fnColdSwap called with $@ where device $new does not exist"
  # Is the old device actually being used in the pv?
  pvs --select vg_name=${vg}|grep -qw ${old} || fnFail "Asked to remove ${old} from ${vg} which is not using it, aborting"
  # Okay. Let's go.
  # Unmount everything using that vg (xargs -r will not run if there's no output, -n1 will run once per entry):
  for path in $(lvs --noheadings -o lv_path ${vg}); do
    # Is this lv mounted? continue if not
    echo "Ensuring $path is not mounted"
    findmnt -n $path || continue
    echo "It is mounted, unmounting"
    umount $path || fnFail "Failed to unmount a filesystem before cold-swapping LVM pvs. Aborting"
  done
  echo "Disabling vg ${vg}"
  vgchange -an ${vg} || fnFail "Failed to vgchange -an ${vg}"
  echo "Deleting ${old}"
  lvmdevices --deldev ${old} || fnFail "lvmdevices --deldev ${old} failed"
  echo "device ${new}"
  lvmdevices --adddev ${new} || fnFail "lvmdevices --adddev ${new} failed"
  echo "Enabling vg ${vg}"
  vgchange -ay ${vg} || fnFail "Failed to vgchange -an ${vg}"
  echo "==> COMPLETED fnColdSwap called with $@"
  echo
}
fnTestVolumesWorkByWritingAndReading() {
  echo
  echo "==> START fnTestVolumesWorkByWritingAndReading called with $@"
  vg="${1}"
  echo "Creating our test file"
  dd if=/dev/urandom of=/tmp/$testfile bs=1M count=1
  original_checksum=$(cat /tmp/$testfile|sha256sum)
  # We are going to methodically perform this on each raid1-type lv in the vg:
  for lvset in $(fnListRaidLvs); do
    lv=$(echo ${lvset}|cut -d: -f1)
    dir=$(echo ${lvset}|cut -d: -f2)
    # Check if it's mounted - and if it isn't mount the volume
    # We need it mounted to check its health
    mountpoint "${dir}" || mount /dev/${vg}/${lv} ${dir} || fnFail "Cannot mount /dev/$vg/$lv on $dir"

    # Make sure we are not inheriting a file from another execution:
    [ -f "${dir}/${testfile}" ] && rm -f "${dir}/${testfile}"

    # Copy our test file to the volume being tested:
    cp /tmp/$testfile $dir/
    # sync, grab a last minute checksum of what is there, unmount and remount:
    sync
    sleep 5
    reread1=$(cat $dir/$testfile | sha256sum)
    umount $dir
    sleep 5
    # Mount it back:
    # This is a likely moment when the lvm stack registers a fault if this is being run while the shim driver is causing trouble
    mount /dev/${vg}/${lv} ${dir} || fnFail "Failed to run mount /dev/$vg/$lv $dir"
    # Grab a second checksum of the file there:
    reread2=$(cat $dir/$testfile | sha256sum)
    if [ "x$original_checksum" = "x$reread2" ]; then
      echo "Successful data recovery from storage"
    else
      # We are not expecting this during normative testing. LVM RAID should prevent this. Stop if encountered:
      fnFail "Corrupt data received - expected $original_checksum but got $reread"
    fi
  done
  echo "==> COMPLETED fnTestVolumesWorkByWritingAndReading called with $@"
  echo
}
fnVerifyStorageWrapper() {
  echo
  echo "=> START fnVerifyStorageWrapper $@"
  vg=${1}
  pv_devicename=${2}
  case $verb in
    verify|all)
      fnDisplayLvmState ${vg}
      expected="r"
      # Big picture - what we expect (the WARNING line is on stderr and doesn't need to be parsed):
      #1 lvs -a -o lv_name,lv_attr,segtype,copy_percent,health_status,devices myvg
      #2 WARNING: RaidLV myvg/mylv needs to be refreshed!  See character 'r' at position 9 in the RaidLV's attributes and its SubLV(s).
      #3 LV              Attr       Type   Cpy%Sync Health          Devices
      #4 mylv            rwi-aor-r- raid1  100.00   refresh needed  mylv_rimage_0(0),mylv_rimage_1(0)
      #5 [mylv_rimage_0] Iwi-aor-r- linear          refresh needed  /dev/mapper/sdb1.flakey(1)
      #6 [mylv_rimage_1] iwi-aor--- linear                          /dev/sdc1(1)
      #7 [mylv_rmeta_0]  ewi-aor-r- linear          refresh needed  /dev/mapper/sdb1.flakey(0)
      #8 [mylv_rmeta_1]  ewi-aor--- linear                          /dev/sdc1(0)
      #
      # If with integrity, it looks like this (each rimage has two children - original data (iorig) and integrity metadata (imeta))
      # mylv                  rwi-aor-r- raid1     100.00   refresh needed  mylv_rimage_0(0),mylv_rimage_1(0)
      # [mylv_rimage_0]       gwi-aor-r- integrity 100.00   refresh needed  mylv_rimage_0_iorig(0)
      # [mylv_rimage_0_imeta] ewi-ao---- linear                             /dev/mapper/sdb1.flakey(26)
      # [mylv_rimage_0_iorig] Iwi-ao---- linear                             /dev/mapper/sdb1.flakey(1)
      # [mylv_rimage_1]       gwi-aor--- integrity 100.00                   mylv_rimage_1_iorig(0)
      # [mylv_rimage_1_imeta] ewi-ao---- linear                             /dev/sdc1(26)
      # [mylv_rimage_1_iorig] iwi-ao---- linear                             /dev/sdc1(1)
      # [mylv_rmeta_0]        ewi-aor-r- linear             refresh needed  /dev/mapper/sdb1.flakey(0)
      # [mylv_rmeta_1]        ewi-aor--- linear                             /dev/sdc1(0)
      # Verifying against state of the tested volume group:
      echo "Displaying state"
      for lvset in $(fnListRaidLvs); do
        lv=$(echo "${lvset}"|cut -d: -f1)
        dir=$(echo "${lvset}"|cut -d: -f2)
        # Check the raid device (line 4 above ) is in expected state:
        lvstate=$(lvs -a -o lv_attr myvg/mylv --noheadings 2>/dev/null |cut -c11)
        if [ "x$expected" != "x$lvstate" ]; then
          echo "VG $vg LV $lv is expected to be in state $expected but it in state $lvstate"
          ((testresult+=10))
        else
          echo "VG $vg LV $lv is in expected state $expected"
        fi
        # Next, check its subvolume children
        # This filtered output of lvs produces: (WARNING is on stderr); space will confuse for loop, replacing with tr to colon as easy field separator
        # Also leaving STDERR warning:
        # WARNING: RaidLV myvg/mylv needs to be refreshed!  See character 'r' at position 9 in the RaidLV's attributes and its SubLV(s).
        # :Attr:LV:Type:Devices:
        # :rwi-aor-r-:mylv:raid1:mylv_rimage_0(0),mylv_rimage_1(0)
        # :gwi-aor-r-:[mylv_rimage_0]:integrity:mylv_rimage_0_iorig(0):
        # :ewi-ao----:[mylv_rimage_0_imeta]:linear:/dev/mapper/sdb1.flakey(14):
        # :Iwi-ao----:[mylv_rimage_0_iorig]:linear:/dev/mapper/sdb1.flakey(1):
        # :gwi-aor---:[mylv_rimage_1]:integrity:mylv_rimage_1_iorig(0):
        # :ewi-ao----:[mylv_rimage_1_imeta]:linear:/dev/sdc1(14):
        # :iwi-ao----:[mylv_rimage_1_iorig]:linear:/dev/sdc1(1):
        # :ewi-aor-r-:[mylv_rmeta_0]:linear:/dev/mapper/sdb1.flakey(0):
        # :ewi-aor---:[mylv_rmeta_1]:linear:/dev/sdc1(0):
        mapfile -t subvol_array < <(lvs -a -o lv_attr,lv_name,segtype,devices "${vg}" 2>/dev/null | grep "rmeta" | grep "flakey" | tr -s " " ":")
        for subvol in "${subvol_array[@]}"; do
          echo "$subvol"|grep -q integrity && continue # Avoid checking integrity subvolume rows (or this becomes an infinite loop), this is just for rmeta rows
          # Pull out the # out of $lv_rmeta_#
          rimage=$(echo "$subvol"|cut -d: -f3|cut -d_ -f3|tr -d "]")
          echo "Identified the impaceted rimage as $rimage"
          # Add the integrity line for that volume to our subvolume array as well:
          mapfile -t -O "${#subvol_array[@]}" subvol_array < <(lvs -a -o lv_attr,lv_name,segtype,devices "${vg}" 2>/dev/null | grep "rimage_${rimage}" | grep "integrity" | tr -s " " ":")
        done
        # We should now have a list of the subvolumes we expect to see an 'r' attribute representing a volume that needs refreshing (eg missing a leg)
        for lv_subvol in ${subvol_array[@]}; do
          #
          # lv attributes are in field2 (cut -d: -f2)
          # subvolume is field 3
          # backingstore is field 5
          # we grab the 'refresh needed' state from the 9th character in the attributes
          subvol_lvattr_9th_character_state=$(echo $lv_subvol|cut -d: -f2|cut -c9)
          subvol=$(echo $lv_subvol|cut -d: -f3)
          subvol_backing_store=$(echo $lv_subvol|cut -d: -f5)
          # Skip integrity volumes because they don't get marked with a 'refresh needed' r attribute:
          # We're left with one rimage or rmeta:
          if [ "x$subvol_lvattr_9th_character_state" != "x$expected" ]; then
            ((testresult++))
            echo "VG $vg LV $lv subvolume $subvol backed by $subvol_backing_store expected 9th attributes character $expected but it is $subvol_lvattr_9th_character_state"
          else
            echo "VG $vg LV $lv subvolume $subvol backed by $subvol_backing_store in expected state $expected"
          fi
        done
      done
      echo "Test result is $testresult"
      ;;
  esac
  echo "=> COMPLETED fnVerifyStorageWrapper $@"
}
fnWaitForRestoreToComplete() {
    timeout_secs=3600
    now=$(date +%s)
    timeout_expires=$((now + timeout_secs))
    while [ $(date +%s) -lt ${timeout_expires} ]; do
      sleep 2
      lvs_output=$(lvs -a -o lv_attr,lv_name,copy_percent $vg --noheadings -S 'segtype = raid1')
      state_attribute=$(echo "$lvs_output"|cut -c11)
      copy_percent=$(echo $lvs_output |awk '{print $3}')
      printf "running command to obtain output: lvs  -a -o lv_attr,lv_name,copy_percent $vg --noheadings -S 'segtype = raid1'\n${lvs_output}\nstate attribute of the volume is $state_attribute\ncopy percent stands at $copy_percent\n"
      [ "${state_attribute}x${copy_percent}" = "-x100.00" ] && echo "Health restored" && return 0
    done
    fnDisplayLvmState $vg
    fnFail "Something went wrong restoring the volume. Aborting"
}
fnRestoreStorageWrapper() {
  echo
  echo "=> START fnRestoreStorageWrapper $@"
  vg="${1}"
  restore_from="${2}"
  restore_to="${3}"
  restore_to_devicename=$(basename $restore_to)
  case $verb in
    restore|all)
      # Make the flakey shim be good again:
      fnEnsureFlakeyDeviceAndRule "${restore_to_devicename}" healthy
      fnDisplayLvmState ${vg}
      set -x
      # Unmount all the lvs on this vg:
      for lvset in $(fnListRaidLvs); do
        lv=$(echo "${lvset}"|cut -d: -f1)
        umount /dev/${vg}/${lv}
      done
      # Disable the vg:
      vgchange -an ${vg}
      sleep 2
      # 1. Force the physical metadata synchronization down to the lagging drive partition
      vgck --updatemetadata ${vg}
      sleep 2
      # 2. Re-activate the Volume Group:
      # This is the command that forces the actual metadata write operation we requested in the previous command to both PVs
      vgchange -ay ${vg}
      sleep 2
      # Disable integrity for the refresh
      lvconvert --raidintegrity n ${vg}
      sleep 2
      # refresh
      lvchange --verbose --refresh ${vg}
      sleep 2
      # Undisable raid integrity:
      lvconvert --raidintegrity y ${vg}
      sleep 2
      echo "Waiting for sync to be complete"
      set +x
      fnWaitForRestoreToComplete
      echo "Cold-swapping pvs in $vg from $restore_from to $restore_to"
      fnColdSwap ${vg} ${restore_from} ${restore_to}
      dmsetup remove ${restore_from}
      fnTestVolumesWorkByWritingAndReading "${vg}" || fnFail "Volume failed unexpectedly when restoring at the end of the test"
      fnDisplayLvmState ${vg}
      ;;
  esac
  echo "=> COMPLETED fnRestoreStorageWrapper $@"
  echo
}

fnTriggerStoragePrepWrapper() {
  echo
  echo "=> START fnTriggerStoragePrepWrapper $@"
  vg=${1}
  pv_shim_devicename=${2}
  pv=${3}
  pv_devicename=$(basename ${pv})
  case $verb in
    trigger|all)
      # These are destructive storage tests. We only proceed if everything checks out at the start:
      # make sure volume is active (vgchange -ay):
      fnCheckLvmVgGActive ${vg} || fnFail "not active, not proceeding"
      # make sure volumes are healthy
      fnCheckLvmVgVolumesHealthy ${vg} || fnFail "not healthy, not proceeding"
      # Create a healthy shim device for the pv we are going to work with:
      fnEnsureFlakeyDeviceAndRule "${pv_devicename}" healthy
      fnColdSwap ${vg} ${pv} ${pv_shim_devicename} # $vg $old $new
      fnTestVolumesWorkByWritingAndReading "${vg}" || fnFail "Volume failed to set up in the trigger prep phase, aborting"
      ;;
  esac
  echo "=> COMPLETED fnTriggerStoragePrepWrapper $@"
  echo
}
fnTriggerStorageFault() {
  echo
  echo "=> START fnTriggerStorageFault $@"
  vg=${1}
  pv_devicename=${2}
  fault=${3}
  case $verb in
    trigger|all)
      vg="${1}"
      pv_devicename="${2}"
      fault="${3}"
      # Tell the flakey device to start introduing faults:
      fnEnsureFlakeyDeviceAndRule "${pv_devicename}" "${fault}"
      # Write data, unmount, remount, and reread it:
      # This step is not intended to check lvm for degraded state, that will come later
      # This step will read, write, mount and unmount each volume and bomb out if LVM fails to maintain service using RAID1:
      fnTestVolumesWorkByWritingAndReading "${vg}" || fnFail "Volume failed unexpectedly when triggering a fault in one of the RAID1 legs"
      ;;
  esac
  echo "=> COMPLETED fnTriggerStorageFault $@"
  echo
}
fnRestoreStorageCleanup() {
  case $verb in
    restore|all) rm -f /tmp/$testfile
                 ;;
  esac
}

# Every volume group, every leg, every fault type:
fnRestoreStorageCleanup
for vg in myvg; do
  for pv in $(pvs --select vg_name=${vg} -o pv_name --noheadings); do
    pv_devicename=$(basename ${pv})
    pv_shim_devicename=/dev/mapper/${pv_devicename}.flakey
    for fault in corruption ioerror; do
      fnTriggerStoragePrepWrapper ${vg} ${pv_shim_devicename} ${pv}; fnTriggerStorageFault ${vg} ${pv_devicename} ${fault}
      fnVerifyStorageWrapper ${vg} ${pv_shim_devicename}
      fnRestoreStorageWrapper ${vg} ${pv_shim_devicename} ${pv}
      [ "x$verb" != "xall" ] && exit 0
    done
    fnRestoreStorageCleanup
  done
done
