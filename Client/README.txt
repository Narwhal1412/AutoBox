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