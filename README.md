# Capstone Project on the Reuse of Old Laptops as a Beowulf Cluster

## Overview
The files listed in this repository are the shell scripts, YAML, and config files I created in the process of making a Beowulf Cluster using old laptops and SFF computers 
that would have otherwise been thrown out. The file directory is laid out below, showing where these files live on the cluster head node. A note that the home/clusteruser is a nfs
mount that is shared between all worker nodes in the cluster. 

## Contents
- All software and hardware information is in Section 1
- Build guide information is in Section 2
- The results information is in Section 3

## Section 1
### Software List
| **Program Name** | **Description** | **Dependecies** |
| ------------     | -----------     | ----------      |
| MPI              | Used for passing instructions between nodes in the cluster | |
| HPL              | The primary testing software for the cluster | |
| Sysbench         | Secondary testing software for individual nodes | |
| Nginx            | | |
| 

### Hardware Information

## Section 2
### Build Guides

### Directory Structure Overview
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
|       |---results
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

## Section 3
 All results are broken down into two (2) parts
 1. Raw CSV files that contain all results for each node and a combined CSV table
 2. Text files containing additional information about test parameters and node environment variables


