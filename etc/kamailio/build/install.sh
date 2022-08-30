#!/bin/sh

# Debug this script if in debug mode
(( $DEBUG == 1 )) && set -x

rm -rf simple-sip-proxy
git clone https://github.com/webstean/simple-sip-proxy

if [ -f /etc/kamailio/kamailio.cfg] ; then rm -f /etc/kamailio/kamailio.cfg ; fi

### cp -r simple-sip-proxy/etc /etc

if ! (cp -v -r simple-sip-proxy/etc/* /etc/) ; then
    echo "Copied Failed!"
    exit 1
fi
echo "Copy succeeded"

if [ -x "$(rtpengine --codecs)" ] ; then
    # /etc/init.d/ngcp-rtpengine-daemon start
    sudo systemctl enable ngcp-rtpengine-daemon
    sudo systemctl status ngcp-rtpengine-daemon
    sudo systemctl start  ngcp-rtpengine-daemon
    sudo systemctl status ngcp-rtpengine-daemon
fi

rtpengine --codecs

# kamailio
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



# Assume kamailio and rtpengine are now installed

# Enable and start firewalld if not already running
systemctl enable firewalld
systemctl start firewalld

# rtpengine Defaults Files
    (cat << 'EOF'
RUN_RTPENGINE=yes
CONFIG_FILE=/etc/rtpengine/rtpengine.conf
# CONFIG_SECTION=rtpengine
PIDFILE=/var/run/rtpengine/rtpengine.pid
MANAGE_IPTABLES=yes
TABLE=0
SET_USER=rtpengine
SET_GROUP=rtpengine
LOG_STDERR=yes
EOF
    ) > /etc/default/rtpengine.conf


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


