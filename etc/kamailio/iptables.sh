#!/bin/bash
iptables -F
iptables -X
# iptables -P INPUT    DROP
# iptables -P OUTPUT   DROP
iptables -P FORWARD  ACCEPT
iptables-restore /etc/kamailio/iptables

