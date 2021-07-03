#!/bin/sh

rm -rf simple-sip-proxy
git clone https://github.com/webstean/simple-sip-proxy
cp -r simple-sip-proxy/etc /etc

grep ifdef /etc/kamailio/kamailio.cfg  | wc -l
grep endif /etc/kamailio/kamailio.cfg  | wc -l

kamailio -f /etc/kamailio/kamailio.cfg -c -ddd
kamailio -v

sudo cp /etc/kamailio/kamailio.service /etc/systemd/system && sudo systemctl daemon-reload
sudo systemctl disable kamailio.service
sudo systemctl enable kamailio.service
sudo systemctl unmask kamailio.service
sudo systemctl status kamailio.service
sudo systemctl start kamailio.service

