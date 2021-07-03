#!/bin/sh

echo Build and Install Kamailio

sudo chown kamailio:kamailio /etc/kamailio/ca_list.pem
sudo chmod 0644 /etc/kamailio/ca_list.pem
