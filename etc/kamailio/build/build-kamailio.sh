#!/bin/sh

if [ -d kamilio ] ; rm -rf kamilio ; fi
git clone https://github.com/kamailio/kamailio kamailio
cd kamailio
git checkout -b 5.5 origin/5.5

sudo apt-get install -y git-core gcc g++ flex bison libmysqlclient-dev make libssl-dev libcurl4-openssl-dev
sudo apt-get install -y libxml2-dev libpcre3-dev libjansson-dev libjson-c-dev
sudo apt-get install -y autoremove
# sqlite
sudo apt-get install -y libsqlite3-0 libsqlite3-dev sqlite3

make include_modules="tls outbound jansson json sqlite" cfg
make all
sudo make install
ls -la /usr/local/lib64/kamailio/modules/tls.so

