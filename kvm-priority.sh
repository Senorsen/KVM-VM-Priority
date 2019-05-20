#!/bin/bash
# KVM VM Priority - stu@lifeofstu.com

CFG_FILE="/etc/libvirt/vm-priority.cfg"

###################################
## TOUCH NOTHING BELOW THIS LINE ##
###################################

# Ensure standard behavior for parsable tools
LANG=C
LC_ALL=C
TZ=UTC
export LANG LC_ALL TZ

# Error handling
function kvm_error {
  echo "ERROR: $1"
  exit 1
}

# Check the configuration file exists
[ -f "$CFG_FILE" ] || \
  kvm_error "The configuration file '$CFG_FILE' is missing"

# Cache ps output to avoid doing it in the loop
PSINFO="$(ps -xo pid,cmd)"

qemu_threads() {
    # List processes that may be threads to a qemu-driven VM
    # e.g. [vhost-1234] CPU threads or [kvm-pit/1234]
    awk '($2 ~ /^\[.*[/-]'"${1}"'\]$/) {print $1}' << EOF
$PSINFO
EOF
}

# Loop through PID's of running VM's
# Also look at qemu machines managed by libvirt
for vm_pid in $(pidof kvm    2>/dev/null | \
                xargs -n 1   2>/dev/null | \
                sort | xargs 2>/dev/null) \
                $(for F in /var/run/libvirt/qemu/*.pid ; do [ -s "$F" ] && cat "$F" && echo "" ; done || true) ; do
  # Get the priorty value and name of the VM
  vm_prio=$(ps -o nice -p $vm_pid 2>/dev/null | \
            tail -n 1 | sed -e 's/^[^0-9\-]*//g')
  vm_name=$(ps -o cmd  -p $vm_pid 2>/dev/null | \
            tail -n 1 | sed -e 's/^[^0-9a-zA-Z]*//g' | \
            sed -e 's/^.*-name\ \([a-zA-Z0-9]*\).*/\1/' 2>/dev/null)
  # Sanity check
  [ "$vm_prio" != "" ] || \
    kvm_error "Unable to retrieve running VM priority"
  [ "$vm_name" != "" ] || \
    kvm_error "Unable to retrieve running VM name"
  # Inform the user of the details
  printf "PID: %5d   -   PRIO: %3d   -   VM NAME: %s   -   IO CLASS AND PRIO: %s\n" $vm_pid $vm_prio $vm_name "$(ionice -p $vm_pid)"
  # Check if a priority level has been configured
  vm_configured=false
  while IFS="|" read vmc_name vmc_prio vmc_ioclass vmc_ioprio ; do
    # Is the line a comment
    case "$vmc_name" in
    "#"*)
      # Comment
      continue
      ;;
    esac
    # Sanity check
    [ "$vmc_name" != "" ] || \
      kvm_error "Found invalid VM name in cfg file"
    [ "$vmc_prio" != "" ] || \
      kvm_error "Found invalid VM priority in cfg file"
    [ "$vmc_ioclass" != "" ] || \
      kvm_error "Found invalid VM IO class in cfg file"
    [ "$vmc_ioprio" != "" ] || \
      kvm_error "Found invalid VM IO priority in cfg file"
    # Check for a match
    if [ "$vmc_name" = "$vm_name" ]; then
      for vm_thread in $vm_pid $(qemu_threads $vm_pid) ; do
        # Match found, check if the priority is different
        [ "$vm_thread" = "$vm_pid" ] || \
          vm_prio=$(ps -o nice -p $vm_pid 2>/dev/null | \
            tail -n 1 | sed -e 's/^[^0-9\-]*//g')
        if [ "$vmc_prio" != "$vm_prio" ]; then
          echo "  - Changing priority for $vm_thread from $vm_prio to $vmc_prio"
          renice -n $vmc_prio -p $vm_thread >/dev/null 2>&1
        else
          echo "  - Priority of $vm_thread is correct, no adjustment needed"
        fi
        # Change the IO settings
        ionice -c $vmc_ioclass -n $vmc_ioprio -p $vm_thread >/dev/null 2>&1
      done
      vm_configured=true
    fi
  done <"$CFG_FILE"
  if ! $vm_configured ; then
    echo "No setting requested for VM $vm_name, skip"
  fi
  echo
done

# All done
exit 0
