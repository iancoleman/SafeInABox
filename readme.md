# Safe In A Box

An easy way to run a customized private [safe network](https://safenetwork.org/).

Note: at this early stage this project is intended for technical users only. If that's not you, try looking at the [public community test network](https://forum.safenetwork.io/search?q=community%20testnet%20order%3Alatest).

# Quick Start

Safe In A Box runs inside a virtual machine. See [setting up a virtual machine](#setting-up-a-virtual-machine).

Copy `install.sh` to the VM.

Run `sudo ./install.sh` on the VM to install and start a private safe network.

Copy the custom apps from the VM to the host, and run the launcher then the demo app.

# Details

This runs a private safe network on a virtual machine.

Vaults run in docker containers inside the virtual machine. This keeps the entire network in a tidy package.

Many properties of the network can be customized, such as number of vaults, account limits etc. See `safe_in_a_box.example.config` for the full range of configuration options. Copy this file to the VM as `safe_in_a_box.config`.

After changing the config file, simply run `sudo ./install.sh` again and it will bring up the newly configured network. The new launcher and demoapp need to be loaded since every new network has a new name, and the old apps won't talk to the new vaults.

The network is built from source, so the code may be modified in many ways beyond just the configuration options.

The first install is very slow (about 1h) because it has to install all the source code and languages etc, but subsequent installs are quite fast (about 3m).

Vault management is handled by [salt](https://docs.saltstack.com/en/latest/). The VM is the salt master and the docker containers running vaults are the minions. Learning a few basic salt commands such as 'cmd.run' and 'state.apply' may be worthwhile for debugging purposes.

Vaults automatically start via a cron job if not already running.

The first vault for boostrapping is stopped after ten minutes and restarted as a normal vault.

Network file shares for the custom apps are via nfs and samba, with details about accessing from the host given at the end of the install log. This makes it relatively simple to access from the host.

# Setting Up A Virtual Machine

These are the settings that worked for me, YMMV.

* Virtualbox running on Ubuntu 16.04 host
* Guest has
    * a clean install of Ubuntu 16.04 Server
    * a second host-only network adaptor running at 192.168.56.1
    * more than 1 cpu. Generally more is better, but don't overwhelm the host by giving it too many.
    * 2GB of ram, absolute minimum is 1GB
    * 20GB drive, absolute minimum is 9GB

It's possible to run this without a virtual machine, ie directly on the host OS, but it's not recommended to do so.

# Helpers

Some helpful commands to run on the VM for determining the state of the vaults:

* Check vault is running

```
salt '*' cmd.run 'ps aux | grep safe_vault | grep -v grep'
```

* Check current routing table size

```
salt '*' cmd.run 'grep Routing /home/*/vault.log | tail -n 1'
```

* List vault salt minion ids

```
salt-key -L
```

* List vault docker container ids

```
docker ps
```

* Run shell for docker instance

```
docker ps # to get instance-id
docker run -i -t <instance-id> bash
```
