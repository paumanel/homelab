# Variable Definitions
variable "proxmox_api_url" {
  type = string
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type        = string
  description = "Name of the node where the template should be created"
}

variable "vm_id" {
  type        = number
  description = "Numerical unique ID for the template"
}

variable "iso_path" {
  type        = string
  description = "Path where the iso is located on the proxmox host"
}

variable "iso_storage_pool" {
  type        = string
  description = "Storage Pool where the iso is located on the Proxmox host"
}

variable "ssh_username" {
  type        = string
  description = "username configured for SSH during provisioning, must match user defined on http/user-data"
}

variable "ssh_private_key_file_path" {
  type        = string
  description = "Path where the private SSH key file is locally stored"
}

variable "vm_conf" {
  type = map(string)
  default = {
    "name"           = "ubuntu-kubernetes"
    "description"    = "Ubuntu template ready for kubernetes"
    "cores"          = "2"
    "memory"         = "2048"
    "disk"           = "10G"
    "disk_type"      = "virtio"
    "disk_pool"      = "local-lvm"
    "disk_pool_type" = "lvm"
  }
}


# Resource Definition for the VM Template
source "proxmox" "ubuntu-server-kubernetes" {

  # Proxmox Connection Settings
  proxmox_url = "${var.proxmox_api_url}"
  username    = "${var.proxmox_api_token_id}"
  token       = "${var.proxmox_api_token_secret}"

  # VM General Settings
  node                 = "${var.proxmox_node}"
  vm_id                = "${var.vm_id}"
  vm_name              = "${var.vm_conf["name"]}"
  template_description = "${var.vm_conf["description"]}"
  os                   = "l26"

  # VM OS Settings
  # (Option 1) Local ISO File
  iso_file = "${var.iso_storage_pool}:iso/${var.iso_path}"
  # - or -
  # (Option 2) Download ISO
  # iso_url = "https://releases.ubuntu.com/22.04/ubuntu-22.04-live-server-amd64.iso"
  # iso_checksum = "84aeaf7823c8c61baa0ae862d0a06b03409394800000b3235854a6b38eb4856f"
  iso_storage_pool = "${var.iso_storage_pool}"
  unmount_iso      = true

  # VM System Settings
  qemu_agent = true

  # VM Hard Disk Settings
  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size         = "${var.vm_conf["disk"]}"
    format            = "raw"
    storage_pool      = "${var.vm_conf["disk_pool"]}"
    storage_pool_type = "${var.vm_conf["disk_pool_type"]}"
    type              = "${var.vm_conf["disk_type"]}"
  }

  # VM CPU Settings
  cores = "${var.vm_conf["cores"]}"

  # VM Memory Settings
  memory = "${var.vm_conf["memory"]}"

  # VM Network Settings
  network_adapters {
    model    = "virtio"
    bridge   = "vmbr0"
    firewall = "false"
  }

  # VM Cloud-Init Settings
  cloud_init              = true
  cloud_init_storage_pool = "${var.vm_conf["disk_pool"]}"

  # Packer Boot Commands
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    "<bs><bs><bs><bs><wait>",
    "autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<wait>",
    "<f10><wait>"
  ]
  boot      = "c"
  boot_wait = "5s"

  # PACKER Autoinstall Settings
  http_directory = "http"

  ssh_username = "${var.ssh_username}"

  ssh_private_key_file = "${var.ssh_private_key_file_path}"

  # Raise the timeout, when installation takes longer
  ssh_timeout = "20m"
}

# Build Definition to create the VM Template
build {

  name    = "ubuntu-server-kubernetes"
  sources = ["source.proxmox.ubuntu-server-kubernetes"]

  # Provisioning the VM Template for Cloud-Init Integration in Proxmox #1
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 1; done",
      "sudo rm /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo apt -y autoremove --purge",
      "sudo apt -y clean",
      "sudo apt -y autoclean",
      "sudo cloud-init clean",
      "sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",
      "sudo sync"
    ]
  }

  # Provisioning the VM Template for Cloud-Init Integration in Proxmox #2
  provisioner "file" {
    source      = "files/99-pve.cfg"
    destination = "/tmp/99-pve.cfg"
  }

  # Provisioning the VM Template for Cloud-Init Integration in Proxmox #3
  provisioner "shell" {
    inline = ["sudo cp /tmp/99-pve.cfg /etc/cloud/cloud.cfg.d/99-pve.cfg"]
  }

  #K8s CRI prerequisites and install
  provisioner "shell" {
    inline = [
      "cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf",
      "overlay\nbr_netfilter\nEOF",
      "sudo modprobe overlay",
      "sudo modprobe br_netfilter",
      "cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf",
      "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\nEOF",
      "sudo sysctl --system",
      "sudo apt update",
      "sudo apt install -y containerd",
      "sudo mkdir -p /etc/containerd",
      "sudo containerd config default | sudo tee /etc/containerd/config.toml",
      "sudo sed -i 's/            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml",
      "sudo systemctl restart containerd",
      "sudo systemctl enable containerd"
    ]
  }

  #K8S installing kubeadm kubelet and kubectl
  provisioner "shell" {
    inline = [
      "sudo apt update",
      "sudo apt install -y apt-transport-https ca-certificates curl",
      "sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt update",
      "sudo apt install -y kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl"
    ]
  }


  # Last cleanup steps
  provisioner "shell" {
    expect_disconnect = "true"
    inline = [
      "cat <<EOF | sudo tee /etc/udev/rules.d/70-persistent-net.rules", #Rename nic to eth0 for cloud init to configure networking
      "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{dev_id}==\"0x0\", ATTR{type}==\"1\", NAME=\"eth0\"\nEOF",
      "sudo rm -f /etc/netplan/00-installer-config.yaml",
      "sudo rm -f /etc/netplan/50-cloud-init.yaml",
      "sudo cloud-init clean",
      "sudo systemctl stop ssh",
      "echo \"sudo killall -e -s SIGKILL sshd\" | sudo at now + 1 minute",     #Kill force kill sshd to logout provsioning user.
      "echo \"sudo userdel -r ${var.ssh_username}\" | sudo at now + 2 minutes" #Fully remove provisioning user.
    ]
  }

  # Shell to allow time for last script to finish
  provisioner "shell-local" {
    pause_before = "4m"
    inline = [
      "echo \"Wait done\""
    ]
  }
}
