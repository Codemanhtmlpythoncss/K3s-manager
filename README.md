installation: ``sudo curl -sfL https://raw.githubusercontent.com/Codemanhtmlpythoncss/K3s-manager/main/k3s-manager.sh -o /usr/local/bin/k3s-manager
sudo chmod +x /usr/local/bin/k3s-manager``

usage: 

install master [--ha] [--worker]        # first master, optional HA + schedulable 

install join-master --server URL --token T [--worker] 

install worker --server URL --token T 

enable-boot / disable-boot 

status / token / list-nodes 

add-node worker|master [--ssh user@host]

remove-node NODE [--purge] [--ssh user@host]

watchdog-install --master IP --standby-ssh-key KEY   # auto-promote on master failure

watchdog-uninstall / promote

uninstall
