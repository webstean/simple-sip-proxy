#!/bin/sh

rm -rf simple-sip-proxy
git clone https://github.com/webstean/simple-sip-proxy
cp simple-sip-proxy/etc/kamailio/kamailio.cfg /etc/kamailio/
cp simple-sip-proxy/etc/kamailio/tls.cfg /etc/kamailio/
cp simple-sip-proxy/etc/kamailio/msteams.list /etc/kamailio/

kamailio -c
systemctl restart kamailio

echo Build and Install Kamailio

kamailio -v

