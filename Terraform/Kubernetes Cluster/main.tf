provider "proxmox" {
  pm_api_url = var.proxmox_provider["url"]
  pm_api_token_id = var.proxmox_provider["token"]
  pm_api_token_secret = var.proxmox_provider["secret"]
}

resource "proxmox_vm_qemu" "master" {
    name = "kmaster1"
    target_node = "theta"
    desc = "Kubernetes master node 1"
    clone = "ubuntu-kubernetes"
    full_clone = "false"
    memory = "4096"
    balloon = "2048"
    disk {
      storage = "local-lvm"
      type = "virtio"
      size = "20G"
    }
    network {
      model = "virtio"
      bridge = "vmbr0"
    }
}