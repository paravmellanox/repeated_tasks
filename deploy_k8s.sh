#!/bin/bash

KUBEADM_CONF_FILE=/etc/systemd/system/kubelet.service.d/10-kubeadm.conf

RDMA_DP_NETDEV=

function write_k8s_rep_file()
{
echo "
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
" > /etc/yum.repos.d/kubernetes.repo
}

function install_k8s()
{
	yum install -y kubelet kubeadm kubectl kubernetes-cni
}

function setup_cgroup_driver()
{
	DOCKER_CGROUP_DRIVER=$(docker info | grep "Cgroup")
	DOCKER_CGROUP_DRIVER=${DOCKER_CGROUP_DRIVER##*:}
	DOCKER_CGROUP_DRIVER=${DOCKER_CGROUP_DRIVER##* }
	if [ $DOCKER_CGROUP_DRIVER = "cgroupfs" ]; then
		sed -i -e 's/cgroup-driver=systemd/cgroup-driver=cgroupfs/g' $KUBEADM_CONF_FILE
	else
		sed -i -e 's/cgroup-driver=cgroupfs/cgroup-driver=systemd/g' $KUBEADM_CONF_FILE
	fi
}

function download_tools()
{
	yum install -y golang git
	
}

function build_install_multus_cni()
{
	cd /tmp
	git clone https://github.com/Intel-Corp/multus-cni.git 
	cd multus-cni 
	./build
	if [ -e bin/multus ]; then
		echo "multus cni build successful."
	else
		echo "Fail to build multus cni."
		exit
	fi
	cp -f bin/* /opt/cni/bin/
	cd $CUR_DIR
}

function build_install_sriov_cni()
{
	cd /tmp
	git clone https://github.com/Mellanox/sriov-cni.git 
	cd sriov-cni 
	./build
	if [ -e bin/sriov ]; then
		echo "sriovs cni build successful."
	else
		echo "Fail to build sriov cni."
		exit
	fi
	cp -f bin/* /opt/cni/bin/
	cd $CUR_DIR
 }

function build_install_cnis()
{
	mkdir -p /etc/cni/net.d
	mkdir -p /opt/cni/bin/
	mkdir -p /tmp/
	cd /tmp
	build_install_multus_cni
	build_install_sriov_cni
	cd $CUR_DIR
}

function setup_kubectl_env()
{
	mkdir -p $HOME/.kube
	cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	chown $(id -u):$(id -g) $HOME/.kube/config
}

function setup_kernel_config_file()
{
	KERNEL_VERSION=$(uname -r)
	KERNEL_CFG_FILE="config-$(uname -r)"
	
	if [ -e /boot/$KERNEL_CFG_FILE ]; then
		echo "Config file $KERNEL_CFG_FILE present"
	else
		cp /lib/modules/`uname -r`/source/.config /boot/$KERNEL_CFG_FILE
	fi
}

function setup_k8s_master()
{
	kubeadm init --pod-network-cidr=$POD_NW_CIDR --apiserver-advertise-address=$API_SERVER_IP --kubernetes-version stable-1.10
}

function setup_flannel()
{
	#read why this to be setup
	#https://kubernetes.io/docs/concepts/cluster-administration/network-plugins/#network-plugin-requirements
	sysctl net.bridge.bridge-nf-call-iptables=1
	
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/v0.9.1/Documentation/kube-flannel.yml
}

function setup_cni_cfg_files()
{
	cp -f multus-cni.conf /etc/cni/net.d/
}

function enable_master_to_run_pods()
{
	kubectl taint nodes --all node-role.kubernetes.io/master-
}

function build_install_rdma_device_plugin()
{
	cd /tmp/
	git clone https://github.com/hustcat/k8s-rdma-device-plugin.git
	cd k8s-rdma-device-plugin 
	go get github.com/hustcat/k8s-rdma-device-plugin
	./build
	cp -f bin/* /usr/bin/
	cd $CUR_DIR
}

function start_rdma_device_plugin()
{
	k8s-rdma-device-plugin -master $RDMA_DP_NETDEV -log-level debug
}

function setup_rdma_device_plugin()
{
	# add send sline for device pluin
	sed -i -e '2iEnvironment="KUBELET_EXTRA_ARGS=--feature-gates=DevicePlugins=true"\' $KUBEADM_CONF_FILE
}

NUM_ARGS=$#
if [ $NUM_ARGS -lt 1 ]; then
	echo "Valid commands are install, setup and start"
	exit
fi

CUR_DIR=$(pwd)

case "$1" in
"install")
	swapoff -a
	setenforce 0
	setup_kernel_config_file
	build_install_cnis
	#build_install_rdma_device_plugin
	setup_cni_cfg_files
	write_k8s_rep_file
	install_k8s
	setup_flannel
	setup_cgroup_driver
	systemctl daemon-reload
;;
"setup")
	if [ $NUM_ARGS -lt 3 ]; then
		echo "Valid command is setup deploy_k8s.sh setup <pod_cidr_ip_with_subnet> <api_server_ip>"
		echo "Example deploy_k8s.sh setup 194.168.1.0/24 10.194.10.1"
		exit
	fi
	POD_NW_CIDR=$2
	API_SERVER_IP=$3
	setup_k8s_master
	setup_rdma_device_plugin
	systemctl daemon-reload
	setup_kubectl_env
	setup_flannel
;;
"start")
	if [ $NUM_ARGS -lt 2 ]; then
		echo "Valid command is start <rdma PF netdevice name such as (ib0/ ens2f0)"
		echo "Example deploy_k8s.sh start ib0"
		echo "Example deploy_k8s.sh start ens2f1"
		exit
	fi
	RDMA_DP_NETDEV=$2
	swapoff -a
	setenforce 0
	setup_kernel_config_file
	systemctl start docker
	systemctl start kubelet
	systemctl status kubelet
	#start_rdma_device_plugin
;;
esac
