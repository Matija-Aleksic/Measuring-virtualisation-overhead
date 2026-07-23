#!/usr/bin/env bash
# =============================================================================
# launch-vm.sh — exact QEMU/KVM invocation used for the Linux-Quemu v5 round
# =============================================================================
# Host: Ubuntu 24.04 LTS @ 192.168.100.180. Guest: Debian 13 (trixie)
# genericcloud, provisioned via cloud-init (user-data + meta-data -> seed.img
# built with `cloud-localds seed.img user-data meta-data`).
#
# Disk: backed overlay off the pristine cloud image, grown to 40G:
#   qemu-img create -f qcow2 -F qcow2 \
#     -b debian-13-genericcloud-amd64.qcow2 benchmark-disk.qcow2 40G
#
# Networking: SLIRP user-mode NAT (QEMU's built-in default NAT) with a virtio
# NIC — deliberately QEMU's own default NAT, consistent with the v5 rule that
# each hypervisor is measured on its native default NAT (VMware vmnet8,
# VirtualBox NAT, Hyper-V internal+NAT). Userspace SLIRP is CPU-heavy, so its
# lower network throughput is a real, explainable part of QEMU's abstraction
# tax — not a misconfiguration. SSH reached at localhost:2222 (hostfwd).
# =============================================================================
cd "$(dirname "$0")"
taskset -c 0-3 qemu-system-x86_64 \
  -name qemu-bench \
  -enable-kvm -cpu host,migratable=off \
  -smp 4,sockets=1,cores=4,threads=1 -m 16G \
  -drive file=benchmark-disk.qcow2,if=virtio,cache=none,aio=native \
  -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -display none -daemonize \
  -pidfile qemu.pid
