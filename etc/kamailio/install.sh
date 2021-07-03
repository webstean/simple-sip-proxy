#!/bin/sh

# exit immediately if non-zero return
# set -e

rm -rf simple-sip-proxy
git clone https://github.com/webstean/simple-sip-proxy
cp -r simple-sip-proxy/etc /etc

dos2unix /etc/kamailio/kamailio.cfg

if ! (kamailio -f /etc/kamailio/kamailio.cfg -c ) ; then
    echo ;
    grep ifdef /etc/kamailio/kamailio.cfg  | wc -l
    grep endif /etc/kamailio/kamailio.cfg  | wc -l
    exit 1
fi

kamailio -v

if [ ! -d /var/run/kamailio ] ; then mkdir -p /var/run/kamailio ; fi

sudo cp /etc/kamailio/kamailio.service /etc/systemd/system && sudo systemctl daemon-reload
sudo systemctl disable kamailio.service
sudo systemctl enable kamailio.service
sudo systemctl unmask kamailio.service
sudo systemctl status kamailio.service
sudo systemctl start kamailio.service

