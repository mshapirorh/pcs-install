#!/bin/bash -x
fnFail() {
        echo "Error: $1"
        exit 1
}
# Import the settings of the cluster:
. ./pacemaker-cluster-settings
fnDeployNode() {
    echo "Performing configuration required by $node"
   
    # Installing cluster software
    # Authoritative documentation:
    https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/assembly_creating-high-availability-cluster-configuring-and-managing-high-availability-clusters#proc_installing-cluster-software-creating-high-availability-cluster
 
    # Ensure high availability repo is on so RPMs can be installed:
    # subscription-manager repos --enable=rhel-9-for-x86_64-highavailability-rpms
    
    # Install rpms:
    dnf -y install pcs pacemaker fence-agents-all || fnFail "Failed to install packages"

    # As we will be using corosync quorum device, we also need to follow the guide to using them here:
    https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/assembly_configuring-quorum-devices-configuring-and-managing-high-availability-clusters#proc_installing-quorum-device-packages-configuring-quorum-devices
    # On each node we also need to install the corosync-qdevice package
    dnf -y install corosync-qdevice || fnFail "Failed to install corosync-qdevice"

    # Enable pacemaker in the local firewall:
    firewall-cmd --permanent --add-service=high-availability
    firewall-cmd --reload

    # Case node 

    # Set the password for the cluster:
    # passwd hacluster
    # We are going to apply the hacluster password programatically from a controlled file that will be removed after install
    cat pacemaker-secret |chpasswd

    # Enable and start the pcsd service:
    systemctl enable --now pcsd

    # TODO: Apply the lvm configuration change
}

fnDeployQuorumNode() {
	# Following the procedure to deploy the quorum node:
	# Note we are operating on a shared quorum node and want to avoid unnecessary intrusive operations where possible
        # https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/assembly_configuring-quorum-devices-configuring-and-managing-high-availability-clusters?utm_source=chatgpt.com#proc_installing-quorum-device-packages-configuring-quorum-devices
        # NOTE: we assume the quorum node is shared and will avoid unnecessary intrusive operations, while being careful not to disrupt existing configuration for other pacemaker clusters
      
        for package in pcs corosync-qnetd; do 
		rpm -q $package || dnf -y install $package
	done
        # make systemctl behave inside a script and not invoke less-like interactive editors:
	export SYSTEMD_PAGER=cat

	systemctl enable pcsd.service
        systemctl status pcsd.service || systemctl start pcsd.service

	if ! pcs qdevice status net --full; do
		pcs qdevice setup model net --enable --start
                pcs qdevice enable net
                pcs qdevice start net
		pcs qdevice status net --full
	done

	firewall-cmd --permanent --add-service=high-availability
	firewall-cmd --add-service=high-availability

}

fnRunFromLastNode() {
	username=`cut -d: -f1 ./pacemaker-secret`
	password=`cut -d: -f2 ./pacemaker-secret`
	# all_nodes_in_a_string=`printf '%s ' "${nodes[@]}"`
	all_nodes_in_a_string=pcs1
	# Authenticate against each node in the cluster:
	for node in pcs1; do
          pcs host auth -u "${username}" -p "${password}" $all_nodes_in_a_string $quorumnode
	done
	# Set up the cluster
	pcs cluster setup "${clustername}" --start $all_nodes_in_a_string
	# And add the quorum node to it as well:
	pcs quorum device add model net host=$quorumnode algorithm=ffsplit

        # Enable cluster services by default:
        pcs cluster enable --all

        # Check cluster status:
        pcs cluster status

	# Check the quorum configuration:
	pcs quorum config
	# And check quorum runtime status:
        pcs quorum status
	# ... and quorum device runtime status
	pcs quorum device status
	# ... ... and some extra information about the corosync demon status:
	pcs qdevice status net --full

	# TODO: Configure stonith:
}

case $thisnode in
	"$quorumnode")	fnDeployQuorumNodes
                        ;;
	"$lastnode")	fnDeployNode
			fnRunFromLastNode
                        ;;
        *)		for node in "${nodes[@]}"; do
                          [ "x$node" != "x$thisnode" ] && continue
                          fnDeployNode
                        done
                        ;;
esac
