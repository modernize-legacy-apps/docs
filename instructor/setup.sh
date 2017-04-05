#!/bin/sh

set -e

subscription_pool_id=8a85f9815691b057015693f571f11cde  # Update this to correctly reflect the pool id of your subscription (subscription-manager list --available --all)

_RHN_USER="tqvarnst@redhat.com"
_RHN_PASSWD=""
_VIRT_MACHINE_NAME=""
_DELETE=false

while (( "$#" )); do
  case $1 in
    -p)
      shift
      _RHN_PASSWD=$1
      ;;
    -u)
      shift
      _RHN_USER=$1
      ;;
    -m) 
      shift
      _VIRT_MACHINE_NAME=$1
      ;;
    --delete) 
      _DELETE=true
      ;;
    *)
      echo "Unknown parameter $1. Aborting"
      exit 1
      ;;
  esac
  shift
done


if $_DELETE && [ ! -z $_VIRT_MACHINE_NAME ]; then 
  virsh shutdown $_VIRT_MACHINE_NAME
  sleep 5
  virsh undefine $_VIRT_MACHINE_NAME
  exit
fi




if [ -z "$_RHN_USER" ]; then 
  read -p 'Type your RHN username: ' _RHN_USER
  echo
fi

if [ -z "$_RHN_PASSWD" ]; then 
  read -s -p 'Type your RHN password (note: there is no response while typeing): ' _RHN_PASSWD
  echo
fi

if [ -z "$_VIRT_MACHINE_NAME" ]; then 
  read -p 'Type the name of the virtual machine that will be created (or deleted): ' _VIRT_MACHINE_NAME
  echo
fi


if [ -z "$_RHN_USER" ]; then 
  echo "RHN user (-u) cannot be empty. Aborting"
  exit 2
fi

if [ -z "$_RHN_PASSWD" ]; then 
  echo "RHN password (-p) cannot be empty. Aborting"
  exit 3
fi


if [ -z "$_VIRT_MACHINE_NAME" ]; then 
  echo "Machine (-m) name cannot be empty. Aborting"
  exit 4
fi




mysha=$(cat ~/.ssh/id_rsa.pub) 

# Customize and start the virtual machine
echo "[HOST] Copying the base template image"
cp /var/lib/libvirt/images/RHEL7.3-template.qcow2 /var/lib/libvirt/images/$_VIRT_MACHINE_NAME.qcow2 

echo "[HOST] Fixing Network in the image"
virt-customize -a /var/lib/libvirt/images/$_VIRT_MACHINE_NAME.qcow2 --run-command 'cp /etc/sysconfig/network-scripts/ifcfg-ens3 /etc/sysconfig/network-scripts/ifcfg-eth0 && sed -i /^IPV6_/d /etc/sysconfig/network-scripts/ifcfg-eth0 && sed -i s/=ens3/=eth0/g /etc/sysconfig/network-scripts/ifcfg-eth0'

echo "[HOST] Adding SHA for remote access to root user"
virt-customize -a /var/lib/libvirt/images/$_VIRT_MACHINE_NAME.qcow2 --run-command "mkdir -p /root/.ssh && echo \"$mysha\" > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && chcon -R -h system_u:object_r:ssh_home_t:s0 /root/.ssh"

echo "[HOST] Adding SHA for remote access to student user"
virt-customize -a /var/lib/libvirt/images/$_VIRT_MACHINE_NAME.qcow2 --run-command "mkdir -p /home/student/.ssh && echo \"$mysha\" > /home/student/.ssh/authorized_keys && chmod 700 /home/student/.ssh && chmod 600 /home/student/.ssh/authorized_keys && chcon -R -h system_u:object_r:ssh_home_t:s0 /home/student/.ssh && chown -R student:student /home/student/.ssh" 


echo "[HOST] Startging the virtual machine with $_VIRT_MACHINE_NAME"
virt-install --memory 16384 --vcpus 4 --os-variant rhel7 \
      --disk path=/var/lib/libvirt/images/$_VIRT_MACHINE_NAME.qcow2,device=disk,bus=virtio,format=qcow2 \
      --import --noautoconsole --vnc --network network:default --name $_VIRT_MACHINE_NAME
    
echo "[HOST] Waiting for the machine initialize"
sleep 10

while [ -z "$ip" ]
do
  sleep 2
  if=$(virsh net-dumpxml default | grep "bridge" | sed "s/.*name='\([a-zA-Z0-9]*\)'.*/\1/g")
  mac=$(virsh domiflist $_VIRT_MACHINE_NAME | awk '/default/ {print $5};')
  ip=$(cat /var/lib/libvirt/dnsmasq/$if.status | jq -r ".[] | select(.\"mac-address\"==\"$mac\") | .\"ip-address\"") 
done
echo "Virtual machine $_VIRT_MACHINE_NAME is installed with ip $ip" 

# Wait for guest to start
printf "[HOST] Waiting for the guest to boot"
while ! ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$ip echo ok;
do
  printf "."
  sleep 1
done
echo


echo "[HOST] Registring the system with user $_RHN_USER"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T root@$ip <<EOSSH
    
    
    echo "[GUEST] Registring the system via subscription manager"
    subscription-manager register --username "$_RHN_USER" --password "$_RHN_PASSWD" > /dev/null && sleep 5 || { echo >&2  "FAILED to register the system to RHN"; exit 1; }
   
    echo "[GUEST] Attaching to subscription pool $subscription_pool_id"
    subscription-manager attach --pool="$subscription_pool_id" > /dev/null || subscription-manager attach --pool="$subscription_pool_id" > /dev/null #Sometimes we have to try twice ;-)
    
    subscription-manager repos --disable="*" > /dev/null
    subscription-manager repos --enable="rhel-7-server-rpms" --enable="rhel-7-server-extras-rpms" --enable="rhel-7-server-ose-3.4-rpms"
    
    echo "[GUEST] Removing libvirt and networking from the Guest"
    virsh net-undefine default > /dev/null
    systemctl stop libvirtd > /dev/null
    systemctl disable libvirtd > /dev/null

    echo "[GUEST] Installing tools etc" 
    yum install -y wget git net-tools bind-utils iptables-services bridge-utils bash-completion atomic-openshift-utils atomic-openshift-excluder atomic-openshift-docker-excluder java-1.8.0-openjdk-devel > /dev/null
    
    echo "[GUEST] Running atomic-openshift-excluder to ensure we have the correct version of docker etc"
    atomic-openshift-excluder unexclude
    
    echo "[GUEST] Installing docker and openshift clients"
    yum install -y docker atomic-openshift-clients > /dev/null
    
    echo "[GUEST] Configuring unsecure registry"
    sed -i '/OPTIONS=.*/c\OPTIONS="--selinux-enabled --insecure-registry 172.30.0.0/16 --log-opt max-size=1M --log-opt max-file=3"' /etc/sysconfig/docker
    
    echo "[GUEST] Enable the docker service and adding student to the docker group"
    systemctl enable docker > /dev/null && groupadd docker && usermod -aG docker student

    echo "[GUEST] Starting docker deamon"
    systemctl start docker > /dev/null

    echo "[GUEST] adding firewall rules"
    firewall-cmd --permanent --new-zone dockerc
    firewall-cmd --permanent --zone dockerc --add-source $(docker network inspect -f "{{range .IPAM.Config }}{{ .Subnet }}{{end}}" bridge)
    firewall-cmd --permanent --zone dockerc --add-port 8443/tcp
    firewall-cmd --permanent --zone dockerc --add-port 53/udp
    firewall-cmd --permanent --zone dockerc --add-port 8053/udp
    firewall-cmd --reload
    
    echo "[GUEST] Installing Visual Studio Code editor"
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
    yum install -y code > /dev/null

EOSSH

#Restart the virtual machine
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T root@$ip shutdown -r now || true


# Wait for guest to reboot
printf "[HOST] Waiting for the guest to reboot"
sleep 2
while ! ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$ip echo ok;
do
  printf "."
  sleep 2
done
echo


echo "[HOST] Installing oc-cluster wrapper"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T student@$ip <<'EOSSH'
    echo "[GUEST] Installing oc-cluster wrapper"
    git clone https://github.com/openshift-evangelists/oc-cluster-wrapper

    echo "[GUEST] Installing maven"
    curl -s http://apache.mirrors.spacedump.net/maven/maven-3/3.3.9/binaries/apache-maven-3.3.9-bin.tar.gz | tar xz -C $HOME && mv ~/apache-maven-3* ~/apache-maven
    
    echo 'export JAVA_HOME=/usr/lib/jvm/java-1.8.0' >> $HOME/.bash_profile
    echo 'export PATH=$HOME/oc-cluster-wrapper:$HOME/apache-maven/bin:$JAVA_HOME/bin:$PATH' >> $HOME/.bash_profile

    echo "[GUEST] Installing Red Hat Java extension to Visual Studio Code Editor"
    code --install-extension=redhat.java
EOSSH

echo "[HOST] Starting oc-cluster and importing xpaas images"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T student@$ip <<'EOSSH'    
    mkdir -p ~/projects

    echo "[GUEST] Downloading monolith project"
    curl -s -L -o /tmp/monolith.zip https://github.com/coolstore/monolith/archive/master.zip && unzip -q -d ~/projects/ /tmp/monolith.zip && mv ~/projects/monolith-master ~/projects/monolith

    echo "[GUEST] Downloading dependencies to monolith project"
    mvn -qf ~/projects/monolith dependency:go-offline
    mvn -qf ~/projects/monolith dependency:go-offline -Popenshift

    echo "[GUEST] Downloading inventory project"
    curl -s -L -o /tmp/inventory.zip https://github.com/coolstore/inventory-wfswarm/archive/master.zip && unzip -q -d ~/projects/ /tmp/inventory.zip && mv ~/projects/inventory-wfswarm-master ~/projects/inventory

    echo "[GUEST] Downloading dependencies for the inventory project"
    mvn -qf ~/projects/inventory dependency:go-offline
    mvn -qf ~/projects/inventory dependency:go-offline -Popenshift


    echo "[GUEST] Starting OpenShift Cluster"
    oc-cluster up
    sleep 5
    
    echo "[GUEST] Login to openshift as syste:admin"
    oc login -u system:admin
    
    echo "[GUEST] Installing xPaaS imagestreams and templates"
    oc-cluster plugin-install imagestreams xpaas

    echo "[GUEST] Importing images"
    for is in $(oc get is -n openshift -o name | sed "s/imagestream\///")
    do 
        oc import-image $is --confirm > /dev/null 2>&1
    done

    echo "[GUEST] Login in to openshift as developer"
    oc login -u developer -p developer
    
    for image in $(oc get is -n openshift | grep "^jboss" | awk '{print $2}')
    do
      docker pull $image
    done

EOSSH

echo "[HOST] Unregistering"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -T root@$ip <<'EOSSH'
    subscription-manager remove --all
    subscription-manager unregister
    subscription-manager clean

    su student -c "rm /home/student/.ssh/authorized_keys"
    su student -c "history -cw"
    history -cw
    rm /root/.ssh/authorized_keys
EOSSH




