 #!/bin/sh
 ##
 set -e
 machine=L103736
 subscription_pool_id=8a85f9815691b057015693f571f11cde  # Update this to correctly reflect the pool id of your subscription (subscription-manager list --available --all)
 
 read -s -p 'RHN password?' rhn_password
 mysha=$(cat ~/.ssh/id_rsa.pub)
 

# Customize and start the virtual machine
echo "[HOST] Copying the base template image"
cp /var/lib/libvirt/images/RHEL7.3-template.qcow2 /var/lib/libvirt/images/$machine.qcow2 

echo "[HOST] Fixing Network in the image"
virt-customize -a /var/lib/libvirt/images/$machine.qcow2 --run-command 'cp /etc/sysconfig/network-scripts/ifcfg-ens3 /etc/sysconfig/network-scripts/ifcfg-eth0 && sed -i /^IPV6_/d /etc/sysconfig/network-scripts/ifcfg-eth0 && sed -i s/=ens3/=eth0/g /etc/sysconfig/network-scripts/ifcfg-eth0'

echo "[HOST] Adding SHA for remote access to root user"
virt-customize -a /var/lib/libvirt/images/$machine.qcow2 --run-command "mkdir -p /root/.ssh && echo \"$mysha\" > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && chcon -R -h system_u:object_r:ssh_home_t:s0 /root/.ssh"

echo "[HOST] Adding SHA for remote access to student user"
virt-customize -a /var/lib/libvirt/images/$machine.qcow2 --run-command "mkdir -p /home/student/.ssh && echo \"$mysha\" > /home/student/.ssh/authorized_keys && chmod 700 /home/student/.ssh && chmod 600 /home/student/.ssh/authorized_keys && chcon -R -h system_u:object_r:ssh_home_t:s0 /home/student/.ssh && chown -R student:student /home/student/.ssh" 


echo "[HOST] Startging the virtual machine with $machine"
virt-install --memory 16384 --vcpus 4 --os-variant rhel7 \
      --disk path=/var/lib/libvirt/images/$machine.qcow2,device=disk,bus=virtio,format=qcow2 \
      --import --noautoconsole --vnc --network network:default --name $machine
    
echo "[HOST] Waiting for the machine initialize"
sleep 10

while [ -z "$ip" ]
do
  sleep 2
  if=$(virsh net-dumpxml default | grep "bridge" | sed "s/.*name='\([a-zA-Z0-9]*\)'.*/\1/g")
  mac=$(virsh domiflist $machine | awk '/default/ {print $5};')
  ip=$(cat /var/lib/libvirt/dnsmasq/$if.status | jq -r ".[] | select(.\"mac-address\"==\"$mac\") | .\"ip-address\"") 
done
echo "Virtual machine $machine is installed with ip $ip" 

# Wait for SSHD to start
printf "[HOST] Waiting for the guest to boot"
while ! ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$ip echo ok;
do
  printf "."
  sleep 1
done
echo


echo "[HOST] Registring the system with password $rhn_password"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T root@$ip <<EOSSH
    
    
    echo "[GUEST] Registring the system via subscription manager"
    subscription-manager register --username "tqvarnst@redhat.com" --password "$rhn_password" && sleep 5 || { echo >&2  "FAILED to register the system to RHN"; exit 1; }
    echo "[GUEST] Attaching to subscription pool $subscription_pool_id"
    subscription-manager attach --pool="$subscription_pool_id" || subscription-manager attach --pool="$subscription_pool_id" #Sometimes we have to try twice ;-)
    
    subscription-manager repos --disable="*"
    subscription-manager repos --enable="rhel-7-server-rpms" --enable="rhel-7-server-extras-rpms" --enable="rhel-7-server-ose-3.4-rpms"
    
    echo "[GUEST] Removing libvirt and networking from the Guest"
    virsh net-undefine default
    systemctl stop libvirtd
    systemctl disable libvirtd

    echo "[GUEST] Installing tools etc" 
    yum install -y wget git net-tools bind-utils iptables-services bridge-utils bash-completion atomic-openshift-utils atomic-openshift-excluder atomic-openshift-docker-excluder java-1.8.0-openjdk-devel
    
    echo "[GUEST] Running atomic-openshift-excluder to ensure we have the correct version of docker etc"
    atomic-openshift-excluder unexclude
    
    echo "[GUEST] Installing docker and openshift clients"
    yum install -y docker atomic-openshift-clients
    
    echo "[GUEST] Configuring unsecure registry"
    sed -i '/OPTIONS=.*/c\OPTIONS="--selinux-enabled --insecure-registry 172.30.0.0/16 --log-opt max-size=1M --log-opt max-file=3"' /etc/sysconfig/docker
    
    echo "[GUEST] Enable the docker service and adding student to the docker group"
    systemctl enable docker && groupadd docker && usermod -aG docker student
    
    echo "[GUEST] Starting docker deamon"
    systemctl start docker
EOSSH

if [ $? -ne 0 ]; then
  echo "[HOST] Initial configration failed.. Aborting"
  exit 1
fi

echo "[HOST] Installing oc-cluster wrapper"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T student@$ip <<'EOSSH'
    echo "[GUEST] Installing oc-cluster wrapper"
    git clone https://github.com/openshift-evangelists/oc-cluster-wrapper

    echo "[GUEST] Installing maven wrapper"
    curl -s http://apache.mirrors.spacedump.net/maven/maven-3/3.3.9/binaries/apache-maven-3.3.9-bin.tar.gz | tar xz -C $HOME && mv ~/apache-maven-3* ~/apache-maven
    
    echo 'export JAVA_HOME=/usr/lib/jvm/java-1.8.0'
    echo 'export PATH=$HOME/oc-cluster-wrapper:$HOME/apache-maven/bin:$JAVA_HOME/bin:$PATH' >> $HOME/.bash_profile
EOSSH

if [ $? -ne 0 ]; then
  echo "[HOST] Installation of oc-cluster maven etc failed.. Aborting"
  exit 1
fi

echo "[HOST] Starting oc-cluster and importing xpaas images"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T student@$ip <<'EOSSH'
    echo "[GUEST] Starting OpenShift Cluster"
    oc-cluster up
    sleep 5
    
    echo "[GUEST] Installing xPaaS imagestreams and templates"
    oc-cluster plugin-install imagestreams xpaas

    echo "[GUEST] Importing images"
    oc login -u system:admin
    oc project openshift
    for is in $(oc get is -n openshift -o name | sed "s/imagestream\///")
    do 
        oc import-image $is --confirm > /dev/null 2>&1
    done
    oc-cluster down

EOSSH

if [ $? -ne 0 ]; then
  echo "[HOST] Failed to start oc-cluster and import xpaas images.. Aborting"
  exit 1
fi

echo "[HOST] Unregistering "
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T root@$ip <<EOSSH
    subscription-manager remove --all
    subscription-manager unregister
    subscription-manager clean

    su student -c "rm /home/student/.ssh/authorized_keys"
    su student -c "history -cw"
    history -cw
    rm /root/.ssh/authorized_keys
EOSSH




