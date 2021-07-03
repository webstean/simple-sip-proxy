#!/bin/sh

rm -rf simple-sip-proxy
git clone https://github.com/webstean/simple-sip-proxy
cp -r simple-sip-proxy/etc /etc

grep ifdef /etc/kamailio/kamailio.cfg  | wc -l
grep endif /etc/kamailio/kamailio.cfg  | wc -l

kamailio -f /etc/kamailio/kamailio.cfg -c
kamailio -v

sudo systemctl daemon-reload
sudo systemctl disable kamailio.service
sudo systemctl enable kamailio.service
sudo systemctl status kamailio.service
sudo systemctl start kamailio.service

