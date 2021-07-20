#!/bin/bash

# effectively disable iptables
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

# enable ssh for anywhere
sudo iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
sudo iptables -A OUTPUT -p tcp --sport 22 -m conntrack --ctstate ESTABLISHED -j ACCEPT

# delete all rules
sudo iptables -F
# delete user chanin
sudo iptables -X

# don't allow anything
sudo iptables -P INPUT    DROP
sudo iptables -P OUTPUT   DROP

# allow forwarding
sudo iptables -P FORWARD  ACCEPT


iptables -F


# now restore
sudo iptables-restore /etc/kamailio/iptables


