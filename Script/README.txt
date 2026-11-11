PROXMOX CONTAINER MANAGER  -  no installation needed
=====================================================

STEP 1 - Make an API token in Proxmox (one time, 1 minute)
  Open your Proxmox web page, then:
  Datacenter > Permissions > API Tokens > Add
    User: root@pam      Token ID: manager (any name)
    UNTICK "Privilege Separation"
  Click Add and COPY THE SECRET - Proxmox shows it only once.

STEP 2 - Double-click the file for your computer
  Windows : START-Windows.cmd
  Mac     : START-Mac.command
  Linux   : START-Linux.sh   (if asked, choose "Run in Terminal")

STEP 3 - Follow the menu
  The first time it asks for your Proxmox address and the token, tests the
  connection, finds your server name by itself and remembers everything.
  After that you just pick a number:
    1 List   2 Create   3 Start   4 Stop   5 Delete
    6 Change CPU/memory   7 Download an OS template   8 Details
  Tip: before your first "Create", use option 7 to download an OS template.

IF YOUR COMPUTER COMPLAINS THE FIRST TIME
  Windows : "Windows protected your PC" -> More info -> Run anyway.
            (If it opens in Notepad, run the .cmd, not the .ps1.)
  Mac     : "cannot be opened" -> right-click the file -> Open -> Open.
            If it says "permission denied", open Terminal once and run:
              chmod +x ~/Downloads/Proxmox-Container-Manager/*.command
  Linux   : right-click the file > Properties > Permissions > allow executing,
            or open a terminal in the folder and run:  sh START-Linux.sh

WHERE ARE MY SETTINGS?
  Windows : C:\Users\<you>\.proxmox_lxc.json  (secret is encrypted for you)
  Mac/Linux: ~/.proxmox_lxc.conf              (readable only by you)
  Delete that file (or use menu option 9) to enter new login details.

FOR POWER USERS (command line)
  Windows : START-Windows.cmd list
            START-Windows.cmd create --vmid 105 --template local:vztmpl/<file> --password-prompt
  Mac/Linux: ./proxmox_lxc.sh list      (run with --help for everything)
