#!/bin/sh

git clone https://github.com/kamailio/kamailio kamailio
cd kamailio
git checkout -b 5.5 origin/5.5

sudo apt-get install -y git-core
sudo apt-get install -y gcc g++
sudo apt-get install -y flex
sudo apt-get install -y bison
sudo apt-get install -y libmysqlclient-dev
sudo apt-get install -y make
sudo apt-get install -y libssl-dev
sudo apt-get install -y libcurl4-openssl-dev
sudo apt-get install -y libxml2-dev
sudo apt-get install -y libpcre3-dev
sudo apt -y autoremove

make cfg
make all
