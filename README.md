# Capstone Project on the Reuse of Old Laptops as a Beowulf Cluster

## Overview
The files listed in this repository are the shell scripts, YAML, and config files I created in the process of making a Beowulf Cluster using old laptops and SFF computers 
that would have otherwise been thrown out. The file directory is laid out below, showing where these files live on the cluster head node. A note that the home/clusteruser is a nfs
mount that is shared between all worker nodes in the cluster. 

## Information
- All nodes in this cluster use Ubuntu Server LTS 26.04
    - For more detailed version and individual node information, go to hosts/gameserver and node/node*
- A list of all the required programs to run the cluster can be found in pxe/cluster-repo-packages.txt
- The raw results of each test run can be found in /results for both HPL and Sysbench 

## Directory Structure Overview
```text
root/  
|---etc/  
|   |---chrony/  
|   |   |---chrony.conf  
|   |   |---conf.d/cluster.conf  
|   |---dnsmasq.d 
|   |---exports 
|   |---fstab 
|   |---hosts 
|   |---netplan/ 
|   |---nfs.conf 
|   |---nginx/ 
|   |   |---conf.d 
| 
|---home/ 
|   |---clusteruser/ 
|       |---hostfile 
|       |---clusteruser.bashrc 
|       |---hpl-runs
|
|
|---srv/
|   |---nfs/
|   |   |---ubuntu.iso
|   |
|   |---tftp/
|   |   |---grub/grub.cfg
|   |   |---pxelinux.cfg/default
|   |   |---".efi,.c32,.0,linux iso kernel"
|   |
|   |---www/
|       |---autoinstall/
|       |   |---meta-data, user-data, vendor-data
|       |---cluster-repo/
|       |   |---"local copies of all necessary software goes here with a package list and package.gz file"
|       |---default.conf
```
