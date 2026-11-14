AutoBox Client
==============

Before using it, ask the owner to prepare the settings and token.

Settings and message
--------------------
Open settings.txt in Notepad. Put the Proxmox IP on the PVE_HOST= line near
the top, for example PVE_HOST=192.168.1.10. Port 8006 is added automatically.
The owner must also fill in PVE_TOKEN_NAME= and PVE_TOKEN_SECRET=.

Edit message.txt in Notepad to change the message shown before the y/n question.
The message must explain that this container is temporary and deleted after
2 days (or update it if the owner changes LIFETIME_DAYS).

Creating the API token in Proxmox
---------------------------------
In the Proxmox web interface, open Datacenter > Permissions > API Tokens and
add a token for root@pam. Give it a name such as client. Untick Privilege
Separation for the simple root-token setup. Copy the secret when it appears;
Proxmox shows it only once. The owner puts the name and secret in settings.txt.

Starting the client
-------------------
Windows: double-click START-Client-Windows.cmd.
macOS: double-click START-Client-Mac.command.
Linux: double-click START-Client-Linux.sh (or choose Run in Terminal).
Answer y to create the container, or n to cancel.

First-run operating system warnings
-----------------------------------
Windows SmartScreen: choose More info, then Run anyway, only if you trust the
person who gave you this folder.
macOS: right-click START-Client-Mac.command and choose Open, then confirm Open.
Linux: in file Properties > Permissions, allow executing the file as a program.

Keep this folder private. The settings file contains the API token and the
shared container root password. Anyone who can read the folder can read them.

VM edition
----------
The VM edition clones a prepared cloud-init template. It does not install an
operating system from scratch. Set VM_TEMPLATE_ID= in settings.txt to the VMID
of the template. The shared VM password is VM_PASSWORD= in settings.txt.

Prepare the template once on the Proxmox host. The following example commands
are UNTESTED; adjust the image URL, VMID, storage, bridge, and temporary login
for your Proxmox installation. Do not reuse the temporary password below.

	cd /var/lib/vz/template/iso
	wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 -O debian-12-genericcloud-amd64.qcow2
	qm create 9000 --name debian-cloud-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
	qm set 9000 --scsihw virtio-scsi-pci
	qm importdisk 9000 debian-12-genericcloud-amd64.qcow2 local-lvm
	qm set 9000 --scsi0 local-lvm:vm-9000-disk-0
	qm set 9000 --ide2 local-lvm:cloudinit
	qm set 9000 --boot order=scsi0 --serial0 socket --vga serial0
	qm set 9000 --agent enabled=1
	qm set 9000 --ciuser debian --cipassword 'TEMPORARY-CHANGE-THIS'
	qm set 9000 --ipconfig0 ip=dhcp
	qm start 9000

Open the VM console, sign in with the temporary cloud-init credentials, and
install and enable the guest agent inside the VM:

	sudo apt-get update
	sudo apt-get install -y qemu-guest-agent
	sudo systemctl enable --now qemu-guest-agent

Shut down the VM cleanly, then convert it to a template:

	qm shutdown 9000
	qm template 9000

The VM's IP only appears when qemu-guest-agent is installed and running inside
the guest. First boot can take 1-3 minutes. If no IP appears, ask the owner.

For a Windows 11 template, set VM_GUEST_OS=windows in settings.txt. The client
does not send cloud-init username, password, or IP settings in this mode.
VM_USER and VM_PASSWORD are only displayed for the person creating the VM;
those credentials must already exist inside the template. Set VM_CLONE_MODE to
linked to request a linked clone (full=0); the default full mode copies the
template disk. VM_CLONE_TIMEOUT sets the clone/start task timeout in seconds.

Starting the VM edition
-----------------------
Windows: double-click START-VM-Windows.cmd.
macOS: double-click START-VM-Mac.command.
Linux: double-click START-VM-Linux.sh (or choose Run in Terminal).
Answer y to create the VM, or n to cancel. The server deletes it automatically
after LIFETIME_DAYS (2 days by default).