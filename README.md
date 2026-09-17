Testing Overview
The Pacemaker Test Harness is used to validate the expected operation of RHEL9 Pacemaker cluster nodes, through the introduction of conditions expected to elicit pacemaker behaviors.
Audience and Core Goals
Ahead of their automation, these tests were performed manually on a development cluster.
The tests are primarily intended to be used to verify clusterware setup ahead of handover of newly-built clusters to application teams.
The tests are written to be flexible, such that the code can be reused on differently shaped clusters, if the list of tests required changes.
They are written to be useable under current tooling conditions, where an enterprise orchestrator (tooling that allows sequencing a workflow that requires some operations on one node, and other operations on another node) is presently not available, and the current method is a terminal window to every node in the cluster, and an operator performing a step or steps on each node partaking in a test in the correct sequence.
The automation goes as far as possible under this starting assumption, but can be woven into fully automated workflows in future upgrade work.
A secondary goal of the tests is to automatically produce artifact evidence of the tests having been performed, of the output produced, of how it was assessed, of how a conclusion these are satisfactory results has been reached, or with recognised issues captured in the tests and brought to the attention of the business.
A third goal of the test harness is to be useful to future application team testing, such that they have an option to call some of these tests from broader application tests where this benefits them.
To be useful in this way, all tests implemented
Operate out of /root/pcs on each of the nodes
Keep logs in /root/pcs/logs on each of the nodes
Use a common configuration file that defines a list of nodes on a cluster, in a specific order - first the ones in one datacenter, then the ones in the second. For example:
nodes=(  
“zlps-sawp-nfv31”
“zlps-sawp-nfv32”  
“blps-sawp-nfv31”
“blps-sawp-nfv32”  
)
that is present in /root/pcs/pacemaker-cluster-config on all the nodes, and is shell syntax that can be included from a bash script. This is the same configuration that is used by the scripts that install the cluster.
Are broken up into stages:
Trigger stage -> Verify stage -> Restore stage

The trigger stage sets up starting working conditions required by the test  
The trigger stage checks condition correctness  
The trigger stage starts an RTO timer.
Tests completed on the same node will calculate the time from this moment to service restoration, and assess if service restoration was achieved in the prescribed time.
Tests that require completion on a different node output this number (seconds since Jan 1 1970, as output by date +%s) on the first node, and the user needs to copy it and pass it as a parameter to the test executed on the next node.  
For example, a test started on node1 that results in STONITH of node1 will require a second execution on node2 to verify the cluster is in the expected state, and to later turn node1 back on in the restore stage. It will assess if the RTO was met using the provided number
The trigger stage triggers the actual failure.
The verify stage methodically checks for the desired behavior of each element (for example, each cluster node) and adds to a testresult variable every state inconsistency it finds.
The restore stage restores the cluster to a requested state (often to the state needed by the next test rather than to the state this test started on), to allow continued seamless execution of the tests without any manual recovery needed.
Nomenclature and Method
Node name aliases - a, b, c and d  
For transferability from cluster to cluster without duplication, both the test names and the code refer to nodes in the cluster, explicitly as defined in the /root/pcs/pacemaker-cluster-config file, as a, b, c and d.
The order in this file needs to be such that a and b are in one datacenter, and c and d are in the other.

In the code, $a, $b, $c and $d resolve to the hostnames of the four nodes in the cluster being worked on.
Test names - 10-ab, 30-ab-c, 60-ab-cd etc.  
The shorthand test names have a sequencing number and several letters that express from where to where services are expected to move in this test, giving the user conducting the test an immediate idea of the nodes involved.
10* soft failover tests on request, involving no outages, one for each node in the cluster.  
20* are hard failover tests for nodes a and b, which isolate a node and result in its STONITH and services restarting elsewhere.  
30-ab-c are a similar hard failover test to the other site  
40* are similar to 20* tests involving nodes c and d a the second site.  
50-cd-a is similar to 30* and involves losing the second site and observer services return to the first.  
60-ab-cd creates a split brain scenario between the datacenters.  
100*tests involve testing LVM storage for correct operation.
The authoritative list of tests is managed by the architecture team in a document that defines them, and explicitly gives each test such a shorthand and uses this nomenclature.  
Test names - 10-ab, 30-ab-c, 60-ab-cd etc.
Test Execution and Verbs
	A test is executed by

Picking the correct machine to run it from.
Specifying the test number.
Specifying a verb. The verb can be
“trigger” (to run all steps in the trigger stage)
“verify” (to run all steps in the verify stage)
“restore” (to run all steps in the restore stage)
“all” (to run all steps in all stages applicable to that test and that node).
The verb effectively tells the test harness what (stage) to do.

Cluster State String and Test Definitions  
Beyond functions, the code defines the tests. Each test expected to do something on a node is defined by a case statement entry, for that test, on that node.
A Cluster State string is used by the test harness to:
Ask the trigger stage to set the cluster in a certain state. See more in the section below for detail on how this is achieved.
Internally check every node, to verify it has been set to its intended state.
Tell the “Verify” node what shape the test expects to find the cluster in.
Ask the restore stage to set the cluster in a certain state, similar to Trigger stage, and, same as with Trigger, verify it was indeed set back.

The string has four characters, each a shorthand for a node state, where,  
. standby  
: online  
+online and running the services  
_ offline (only from a pacemaker standpoint, the VM may be on)  
X offline (and the VM is OFF)
For example:
case "${test}--`hostname -s`" in  
…  
20-ab--$a)   fnTriggerWrapper "+:::" ; fnTriggerStartRTO ; fnTriggerDropNetwork ;;  
20-ab--$b)   sleep 30 ; fnVerifyWrapper "X+::" rto180 ; fnRestoreWrapper ":+::" ;;
Breakdown:

These two lines define the 20-ab test. The first, what actions to perform on node $a, the second, on node $b. No actions will be performed if this test is run on nodes $c or $d.
The first line says “when 20-ab is run on node a, execute the following:”
Its invocation will look like this:
a:/root/pcs# ./pacemaker-test-harness.sh 20-ab all
The function names (fnTrigger…) imply they perform something when the user requested the verb “trigger” (or “all”, which includes “trigger”). They will do nothing and skip out if the user requested “verify” or “restore”.
The first function will set the cluster in a state defined by the “+:::” string. This means all nodes online, and services running on a.
The second will start the RTO timer, and generate a timestamp (for example “1789612959”.
The third fnTrigger command will trigger the outage. Right before it does so, it will display “1789612959” on the screen so the user can use this timestamp, and drop the networking on the node.
At this point, node $a will become inaccessible. Pacemaker will be expected to STONITH this node.
Note: the test intentionally does not turn the node off. It verifies not only that the resources are restarted on a good node, but it will also verify that node a with the broken network, which was NOT shut down by the trigger command directly, gets STONITHed by pacemaker, thereby testing STONITH functionality as well.

The second line says “when 20-ab is run on node b, execute the following:”
	The invocation of this test will be:  
b:/root/pcs# ./pacemaker-test-harness.sh 20-ab all 1789612959  
note: the timestamp of the outage start from the first node is specified.
It sleeps for 30 seconds, allowing STONITH and cluster state to reassert.
fnVerifyWrapper "X+::" rto180 - performs a non-intrusive fnVerify function, instructed to
Check the cluster is in “X+::” state. Meaning
The first node needs to be “X” - eg verified (using the fencing agent interface to the hypervisor) to be hard OFF.
The second node needs to be “+” - Online and running the resources, which will be verified.
The third and fourth nodes need to remain online.
Check that at the end, whether we met an rto of 180 seconds. It will subtract the outage start timestamp we passed in from the timestamp as of when everything is back, and assert if the difference is within 180 seconds.
fnRestoreWrapper ":+::”  - takes our cluster, that now has one VM shut off and services running on the second node, and returns it to a state. In this case, it preemptively sets it to the state the next test (21-ba) will want the cluster to start from.  
The first node now needs to be in state “:”, online. The harness will use the fencing agent to restart the node, and then iterate on each of the cluster nodes, ensuring they are where they should be.  
Note: If the services move to the first node, the wrapper will correct this too, and move the services (using iterative pcs resource move) to the location the test requested.

–  
In this manner, additional tests can be designed and introduced as required.  
The fnTriggerWrapper and fnRestoreWrapper functions are largely universal, and can be used to request almost any cluster state with minimal effort.
Similarly, the fnVerifyWrapper function can be requested to easily assert any cluster state that might result from induced conditions or events.
Special Case: The “....” State (all nodes on standby).
Requesting this particular state makes the test harness perform one extra change.
By default, a cluster with running services all of whose nodes are set to standby, will keep the resources running on the last available standby node. This is due to a philosophy of erring on the side of workload safety pacemaker design philosophy. The node will be in a unique “Standby with Services” state.
The test harness treats “....” as a request to
Disable this behavior, as this the use-case here is testing. When an all-standby request is issued, it will flip this property.
Any subsequent request setting the cluster in any other state will flip this back.
Once it then standbys all nodes, pacemaker will shut down the resources.
This behavior is used in storage testing, to request pacemaker to back down ahead of storage testing.
Standard Operating Procedure
Under the current tooling setup (whereby no workflow orchestrator can perform all stages on all nodes for any given test), the following procedure is used.
NOTE: We will run the commands without spending time reviewing success or failure. If the test observably aborts due to unexpected fault, stop the procedure and triage/troubleshoot the problem.  
While you can keep an eye on whether each test reports in its last line success or failure, do not spend time picking logs apart at this state. At the end of the testing, a log summary tool will extract a high level view of what occurred in each log, and reviewing the summaries is far quicker. Only dive into the detailed logs if required from there.
Instructions on generating the summaries will be provided at the end of the SOP.
The steps:
Request and verify privileged access to each of the nodes in the cluster intended to be tested.
Open four terminal windows, side-by-side, one for the four cluster nodes. It is highly recommended to order them by the exact order of the nodes in the node list the test harness uses. This will make the execution more intuitive, as well as reduce the likelihood of human error.
On each, after a sudo su -, run:
# cd /root/pcs
Tests 10-15: On the first node, execute all the non-intrusive tests that test services failover between the nodes. Note you do not need to run tests 10-15 tests from different nodes, as no nodes will be torn down by the test.
Manually:
a:/root/pcs# ./pacemaker-test-harness.sh 10-ab all
a:/root/pcs# ./pacemaker-test-harness.sh 11-ba all
a:/root/pcs# ./pacemaker-test-harness.sh 12-ab-c all
a:/root/pcs# ./pacemaker-test-harness.sh 13-cd all
a:/root/pcs# ./pacemaker-test-harness.sh 14-dc all
a:/root/pcs# ./pacemaker-test-harness.sh 15-dc-a all
Or using a single loop call for ease:
a:/root/pcs# for test in 10-ab 11-ba 12-ab-c 13-cd 14-dc 15-dc-a; do ./pacemaker-test-harness.sh $test all ; done
This should be a quick test, and a good first capability wet test, to make sure the stack starts properly on each of the nodes.
Tests 20-50
Test 20-ab

a:/root/pcs# ./pacemaker-test-harness.sh 20-ab all
Capture the timestamp in the output. The machine will be lost. Do not restart the shell yet.
b:/root/pcs# ./pacemaker-test-harness.sh 20-ab all <TIMESTAMP>
This will complete the test, produce a log with a verdict, and return the cluster to working order.
Restart your shell on node a, re-log-in, and cd to /root/pcs

Test 21-ba
b:/root/pcs# ./pacemaker-test-harness.sh 21-ba all
Capture the timestamp in the output. The machine will be lost. Do not restart the shell yet.
b:/root/pcs# ./pacemaker-test-harness.sh 21-ba all <TIMESTAMP>
This will complete the test, produce a log with a verdict, and return the cluster to working order.
Restart your shell on node b, re-log-in, and cd to /root/pcs
Test 30-ab-c
b:/root/pcs# ./pacemaker-test-harness.sh 30-ab-c all
Capture the timestamp in the output. The machine will be lost. Do not restart the shell yet.
Note: we do not isolate node b for this test by running steps on it directly to kill its network the way we did on node a. We simply set it to standby from here on node a, to disqualify it as a recovery option.

c:/root/pcs# ./pacemaker-test-harness.sh 30-ab-c all <TIMESTAMP>
This will complete the test, produce a log with a verdict, and return the cluster to working order.
Restart your shell on node a, re-log-in, and cd to /root/pcs
Test 40-cd
c:/root/pcs# ./pacemaker-test-harness.sh 40-cd all
Capture the timestamp in the output. The machine will be lost. Do not restart the shell yet.
d:/root/pcs# ./pacemaker-test-harness.sh 40-cd all <TIMESTAMP>
This will complete the test, produce a log with a verdict, and return the cluster to working order.
Restart your shell on node a, re-log-in, and cd to /root/pcs
Test 41-dc
d:/root/pcs# ./pacemaker-test-harness.sh 41-dc all
Capture the timestamp in the output. The machine will be lost. Do not restart the shell yet.
c:/root/pcs# ./pacemaker-test-harness.sh 41-dc all <TIMESTAMP>
This will complete the test, produce a log with a verdict, and return the cluster to working order.
Restart your shell on node a, re-log-in, and cd to /root/pcs
Test 50-cd-a
c:/root/pcs# ./pacemaker-test-harness.sh 50-cd-a all
Capture the timestamp in the output. The machine will be lost. Do not restart the shell yet.
Note: we do not isolate node b for this test by running steps on it directly to kill its network the way we did on node a. We simply set it to standby from here on node a, to disqualify it as a recovery option.

c:/root/pcs# ./pacemaker-test-harness.sh 50-cd-a all <TIMESTAMP>
This will complete the test, produce a log with a verdict, and return the cluster to working order.
Restart your shell on node a, re-log-in, and cd to /root/pcs
Test 60-ab-cd
Before running, take a moment to familiarize yourself with the expected behavior in this test. This is a split brain test. It will prevent two nodes from being able to send network packets to the other two nodes, creating two halves of a cluster, 2 nodes each, whereby neither half can talk to the other.
Furthermore, as the cluster has a fifth quorum node, and both halves will be able to see the quorum node and obtain a vote from it, both halves will deem themselves quorum, in the game, and qualified to run the workload.
Before they do, however, as the configured data safety measure, each half will endeavour to STONITH both nodes it cannot see (the other half), creating a situation resolved (by design) through a STONITH race with an unpredictable outcome.
The test cannot predict which side will win the race. Some executions of this test will result with nodes a and b being terminated, other executions will result in the termination of c and d.

Run the following steps to perform the test:

Within 2-3 seconds of each other, run the following two commands on nodes a and b:
a:/root/pcs# ./pacemaker-test-harness.sh 60-ab-cd all
b:/root/pcs# ./pacemaker-test-harness.sh 60-ab-cd all
	Capture the timestamp in the output **from node a**.   
		  
This will use an ip route blackhole on each of the nodes it is run on, which blocks packets to the two nodes on the other half. It only needs to be performed on two nodes to affect all four, as it will block inbound traffic from the other two as well.
This method is also useful as both a reboot or an ip route command can undo it.
Wait for approximately 2 minutes, then test which two of your four terminal windows have stopped responding.

Scenario A - If nodes c and d have stopped responding, node a will continue on (you do not need to run anything else, it is still running the last command it was given) performing the Verify stage, and a more complex Restore stage which:
It will locally undo the blackhole on its own networking without a reboot.
performs a recover-by-rebooting STONITH operation to reset the network blackhole on its site partner, node b. This saves extra manual steps on node b.
Restarts nodes c and d using the fencing agent, which, upon restart, will again be able to communicate with nodes a and b.
Sets the cluster in the requested state.

No further steps need to be run, the test is complete under this scenario A.

Scenario B - If nodes a and b have stopped responding, nodes c and d won the race.  
Execute the remaining part of the test on surviving node c, remembering to provide it a timestamp:  
a:/root/pcs# ./pacemaker-test-harness.sh 60-ab-cd all <TIMESTAMP>  
Restore is simpler in this scenario, where node c simply brings back nodes c and d using the fencing agent
Test 100-storage

This test is different to the other tests as it tests LVM RAID1 Mirrored Storage rather than Pacemaker for correct operation under duress.

It uses different wrapper functions, namely fnStorageTriggerPrepWrapper, fnStorageVerifyWrapper and fnStorageRecoveryWrapper. They operate on the same principle.

There are two ways to run this test series:
As a series of individual tests, where each can be run piecemeal (trigger separately, verify separately, restore separately). This is labor intensive.
or
As a single execution, which will iterate on all the LVM VGs in the cib (usually just one), all the raid legs it uses (usually two), and all the error test modes for that leg (while there are two - introduce I/O errors, to one leg, or introduce data corruption to one leg). This is time-efficient, but only works with verb “all”.
The test ends when LVM recognises the volume has an issue, raises the attributes, and gets tested to behave as expected.
IOERROR is the current standard test.
NOTE: The corruption test would require further work to make reliable, as in some executions, LVM always prefers the faster (local datacenter) leg for read preference, and when corruption was introduced to the unpreferred leg, forcing it to grab data from the slower faraway leg requires configuration modification (undesired when testing the LVM configuration itself) or introduce additional I/O stress tooling (such as “fio”).

Each node must be done in turn, and never do more than one node at a time.  
a:/root/pcs# ./test-pacemaker-harness.sh 100-storage all  
When done:  
b:/root/pcs# ./test-pacemaker-harness.sh 100-storage all  
When done:  
c:/root/pcs# ./test-pacemaker-harness.sh 100-storage all  
When done:  
d:/root/pcs# ./test-pacemaker-harness.sh 100-storage all
Each execution will take between 5 and 30 minutes, which may vary depending on the size of the storage.
The following events will occur on the node   
once per vg x once per pv x once per error mode  
Assuming
one Volume Group (VG) configured in pacemaker
two Physical Volumes (PV) configure for the VG
only ioerror as the error testing mode used  
1 x 2 x 1 = 2 iterations.
In each iteration:  
Trigger stage:
Set pacemaker to a “....” (full warm standby) mode with all nodes on standby, and all resources stopped.
Trigger stage will place the VG under local lvm control for the duration of this test.
Trigger stage will create a dm-flakey (error injection) shim device for the leg being tested. If the leg is /dev/sdd1, the shim device will be /dev/mapper/sdd1.flakey and it will be set up with /dev/sdd1 as its backing store. It will be configured to act in healthy passthrough mode at this point.
The volume group will be made disabled by LVM.
The volume group will have the PV leg (/dev/sdd1 in our example) removed.
The volume group will have the shim device added in its place.
The volume group will be enabled. A file on /tmp in the known generated out of urandom, with a known checksum can be written to the volume being tested, disk caches synced, the volume can be unmounted and remounted, the file can be re-read, and the checksum of the read file is identical to the checksum of the original. This will iterate on every logical volume.
With all of this verified, and while the filesystems are mounted, the error state on the shim device will be triggered, causing the mirror to start misbehaving.
Verify stage:
lvm lvs attributes will be reviewed to ensure lvm has become aware that one of the legs servicing its mirror is not acting as it should. This is visible in the second last lv attribute becoming ‘r’.
NOTE: when running the other corruption test, this is the stage where LVM does not pick up on the error right away, and it takes a read specifically from the bad mirror (which may be the slower remote site one) for LVM to realize the data integrity checksums are failing. This issue is why secondary corruption adequate behavior testing is currently disabled.
That despite one lost leg, the volume remains able to re-perform the transfer of the test file, unmount, remount, read and checksum pass of the file, deleting the file when done.
Restore stage:
The filesystems are unmounted.
The shim device is configured back to a healthy state.
The logical volume(s) have integrity removed, a restore (re-synchronising the two mirrors) and the integrity mechanism re-enabled.
The script will  patiently wait for the sync of all the volumes to complete. This is the time consuming part of the process.
Upon completion, the volume group is disabled, the shim device is removed and replaced with the original disk (/dev/sdd1) to restore the original configuration.
The cluster VG is eliminated from the LVM managed volume_list
The cluster is restarted and verified to work.
This concludes the iteration.
Known Issues
Any event that causes early termination of the storage test, leaving a shim leg  
In the event of early storage test termination, the LVM state may end up in a state where one of its legs was left configured as /dev/mapper/sdd1.flakey (to use the example).
In this case, observe the two legs using the pvs command, and identify which one (let’s say /dev/sde1) is currently replaced by a shim (/dev/mapper/sde1.flakey)  
use the following command to take the system back to its intended state before starting again.  
CAUTION: MAKE SURE YOU ARE SPECIFYING THE CORRECT LEG. REPLACING THE WRONG (LAST GOOD) LEG MAY RESULT IN DATA LOSS.  
# CURRENT=/dev/mapper/sde1.flakey  
# DESIRED=/dev/sde1
# ./pacemaker-test-harness.sh just storagerestore $CURRENT $DESIRED

Repeat STONITH testing where a node with a mounted filesystem sees a STONITH event may require subsequent filesystem checks. Such checks can be scheduled on a restart and included in future revised versions of tests.
Some clusters are configured with a STONITH policy of REBOOT rather than OFF. This achieves different behavior, whereby tests 20-50 are expected to return an UNSUCCESSFUL (testresult 88) on such clusters. The need for such configuration is under review.
In an event of absolute datacenter cutoff, where not only the nodes fail to see each other, but none of the four storage nodes can access the remote storage disk mapped to it, storage on the active node will continue to work, however, due to the use of the integrity layer, moving the service to an alternate node may refuse to start the LVM VG while one of its legs is missing. In such an event and if restarting the node or moving services to another node were to be triggered, refusal to mount single-leg-equipped storage with an integrity layer would result in all four nodes dropping the service.
