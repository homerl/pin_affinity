#!/bin/bash
###########################################################################
# Script:       $0
# Author:       Homer Li
# Modify:       Homer Li
# Date:         2015-05-08
# Update:       2017-05-08
# Email:        liyan2@genomics.org.cn
# Usage:        $0
# Discription:  Automatic allocate cpu cores for some of pcie devices, find pcie device numa node number
# and equally distributed cpu cores from the numa node
# 
###########################################################################
usage() {
     echo "Usage: $0 SAS3008 82599 X710...." 1>&2; 
     echo "Could lspci | grep SAS3008 to found the pcie addr " 1>&2; exit 1;
}
if [ $# -lt 1 ]
then
  usage
fi

declare -a cpu_nodes
export nodes=$(ls /sys/devices/system/node | grep node -c)
export ENHT=2 #0 means enable hyper threading , 1 is disabled
export cpu_pin="/dev/shm/cpu_pin_hex"
export pcidevpath="/dev/shm/pciedev"
export hex_path="/dev/shm/hex"

cpu_nodes=()
for ((i=0;i<$nodes;i++))
do
    cpu_nodes=([$i]=$(ls /sys/devices/system/node/node$i | awk -F'[ cpu]+' 'BEGIN{ORS=","}; $0~/cpu[0-9]/ {print $2}'))
    echo  ${cpu_nodes[$i]}
done
cpun=$(grep -c processor /proc/cpuinfo)
echo "cpu numa node number is: "$nodes
echo

for ((i=0;i<$cpun;i++)); 
do 
  cat /sys/devices/system/cpu/cpu$i/cache/index2/shared_cpu_list | while read line
  do
     echo -n $line | awk -F, '{if($1<$NF) {printf "%d %d", $1,$NF} else {printf "%d %d", $NF,$1} }';
     echo " "$(ls /sys/devices/system/cpu/cpu$i | grep node | grep -o [0-9])
  done
done | awk '{
   a[$1" "$2]=$3;
   PROCINFO["sorted_in"] = "@val_num_asc" 
   } END{
     for(i in a) {
       print i,a[i]
     }
   }' | awk '{printf "%x %x %d\n", 2^$1,2^$2,$NF}' | tee $cpu_pin


#github.com/vinsonlee/kernel-drivers/blob/master/mpt3sas-11.00.00.00/scripts/set_affinity.sh
### Device name
[ ! -d $pcidevpath ] && mkdir $pcidevpath
foundev() {
    lspci | awk -v devname=$1 '$0~devname {print $1}' | while read line; 
    do 
        devpath=$(dirname $(find /sys  -name "numa_node" | grep $line))
        nodenum=$(cat $devpath"/numa_node") 
        mkdir -p $pcidevpath"/"$nodenum && echo -n > $pcidevpath"/"$nodenum"/"$line
        ls $devpath"/msi_irqs" | tee $pcidevpath"/"$nodenum"/"$line > /dev/zero
    done
}


pin_pcie() {
     [[ ! -d $hex_path ]] && mkdir $hex_path
     phy_cpus=$(cat $cpu_pin | wc -l)
     node_nums=$(ls $pcidevpath"/"$n | wc -l)
     fnr=0 #line number mapping cpu number
     enr=0
     echo "log file in "$hex_path
     for n in $(ls $pcidevpath) # n is numa node number in system
     do
         devn=$(ls $pcidevpath"/"$n | wc -l)
         cpusperdev=$((${phy_cpus}/${node_nums}/${devn})) #per dev mapping cpu number, don 't know real hex number
         for m in $(ls $pcidevpath"/"$n) #m is pci addr name under numa node
         do
         echo "numa node:"$n" single dev mapping cpu number:"$cpusperdev" m is pci addr name:"$m
         #touch $hex_path"/"$m
         ((enr=$enr+$cpusperdev))
         echo "fnr:"$fnr" enr:"$enr
         awk -v node_num=$n '{
            if(NF==3 && $3==node_num) {
               print $1,$2
	    } 
            if (NF==2 && $2=node_num) {
               print $1
            }
         }' $cpu_pin | awk -v fnr=$fnr -v enr=$enr '{
            if(fnr<NR && NR<=enr) {
               print $1
               print $2
            }
            if(fnr<NR && NR<=enr && length($2)==0) {
               print $1
            }
         }' > $hex_path"/"$m
         ((fnr=$fnr+$cpusperdev))
         done
         fnr=0 #line number mapping cpu number
         enr=0
     done
}

mapping_irq() {
     find $pcidevpath -type f | while read line
     do
        echo "#### mappping_irq begin------------"
        cutcount=1
        basen=$(basename $line)
        dirn=$(dirname $line)
        cpu_hex=$(find ${hex_path} -name $basen | xargs cat)
        arr_length=$(echo $cpu_hex | awk '{print NF}')
        for i in $(cat $line) #i is single irq number
        do
          [[ $cutcount -gt $arr_length ]] && cutcount=1 
          core=$(echo $cpu_hex | cut -d" " -f $cutcount)
          if [[ $((${core}/100000000)) -gt 0 ]]
          then
             echo "echo $((${core}/100000000))",00000000" > /proc/irq/${i}/smp_affinity"
          else
             echo "echo ${core} > /proc/irq/${i}/smp_affinity"
          fi
          ((cutcount ++))
        done
     done
}

[[ $(awk 'END{print NF}' $cpu_pin) -eq 3 ]] && echo "Enable HT" && export ENHT=0
[[ $(awk 'END{print NF}' $cpu_pin) -eq 2 ]] && echo "Disable HT" && export ENHT=1
###############get parameter#############
echo "#### disable irq balance"
echo systemctl disable irqbalance
echo systemctl stop irqbalance
echo sysctl -w kernel.perf_event_max_sample_rate=40000
grep numa_balancing /etc/sysctl.conf || echo "kernel.numa_balancing=0" >> /etc/sysctl.conf && sysctl -p
for ar in ${BASH_ARGV[*]}
do
   foundev $ar
done
pin_pcie
mapping_irq
