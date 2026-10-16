The files listed in this repository are the shell scripts, yaml, and config files I created in the process of making a Beowulf Cluster using old laptops and SFF computers 
that would have otherwise been thrown out. The file directory is laid out below for where these files all live in the head node of the cluster. A note that the home/clusteruser is a nfs
mount that is shared between all worker nodes in the cluster





root/ \n
|---etc/ \n
|   |---chrony/ \n
|   |   |---chrony.conf \n
|   |   |---conf.d/cluster.conf \n
|   |---dnsmasq.d \n
|   |---exports \n
|   |---fstab \n
|   |---hosts \n
|   |---netplan/ \n
|   |---nfs.conf \n
|   |---nginx/ \n
|   |   |---conf.d \n
| \n
|---home/ \n
|   |---clusteruser/ \n
|       |---hostfile \n
|       |---clusteruser.bashrc \n
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
