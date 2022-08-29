#!/bin/sh

# exit immediately if non-zero return
# set -e

rm -rf simple-sip-proxy
git clone https://github.com/webstean/simple-sip-proxy

if [ -f /etckamailio/kamailio.cfg] ; then rm -f /etc/kamailio/kamailio.cfg ; fi

### cp -r simple-sip-proxy/etc /etc

if ! (cp -v -r simple-sip-proxy/etc/* /etc/) ; then
    echo "Copied Failed!"
    exit 1
fi
echo "Copy succeeded"

if [ -x "$(dos2unix)" ] ; then
    # just in case
    dos2unix /etc/kamailio/kamailio.cfg
    dos2unix /etc/kamailio/msteams.list
    dos2unix /etc/kamailio/tls.list
fi

if ! (kamailio -f /etc/kamailio/kamailio.cfg -c ) ; then
    echo ;
    #grep ifdef /etc/kamailio/kamailio.cfg  | wc -l
    #grep endif /etc/kamailio/kamailio.cfg  | wc -l
    #kamailio -f /etc/kamailio/kamailio.cfg --cfg-print
    exit 1
fi

kamailio -v

if [ ! -d /var/run/kamailio ] ; then sudo mkdir -p /var/run/kamailio ; fi

sudo systemctl stop kamailio.service && sudo systemctl stop rtpengine.service

sudo systemctl stop rtpengine.service
sudo systemctl stop kamailio.service
sudo systemctl disable rtpengine.service
sudo systemctl disable kamailio.service

# copy in service files
sudo cp /etc/kamailio/kamailio.service /etc/systemd/system 
sudo cp /etc/rtpengine/rtpengine.service /etc/systemd/system
sudo systemctl daemon-reload

chmod +x /etc/rtpengine/rtpengine-start-pre.sh
chmod +x /etc/rtpengine/rtpengine-stop-post.sh
chmod +x /etc/kamailio/iptables.sh

# rtpengine
sudo systemctl enable rtpengine.service
#sudo systemctl unmask rtpengine.service
sudo systemctl start rtpengine.service

# kamailio
sudo systemctl enable kamailio.service
#sudo systemctl unmask kamailio.service
sudo systemctl start kamailio.service

echo Waiting....
sleep 5
# sudo systemctl status kamailio.service
#kamcmd permissions.addressDump
#kamcmd permissions.subnetDump 
# short, short-precise, short-iso, short-iso-precise, short-full, short-monotonic, short-unix,
# verbose, export, json, json-pretty, json-sse, cat
kamcmd dispatcher.list | egrep "URI|FLAGS"
sudo systemctl status kamailio.service  --output=short --lines=5 --no-pager 
sudo systemctl status rtpengine.service --output=short --lines=5 --no-pager 

# check certificate - without validation
openssl s_client -connect localhost:5061 -tls1

# check certificate - with validation
openssl s_client -connect localhost:5061 -tls1 -CAfile /etc/certs/demoCA/cert.pem


