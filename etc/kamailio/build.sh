#!/bin/sh

git clone https://github.com/kamailio/kamailio kamailio
cd kamailio
git checkout -b 5.5 origin/5.5

sudo apt-get install git-core
sudo apt-get install gcc g++
sudo apt-get install flex
sudo apt-get install bison
sudo apt-get install libmysqlclient-dev
sudo apt-get install make
sudo apt-get install libssl-dev
sudo apt-get install libcurl4-openssl-dev
sudo apt-get install libxml2-dev
sudo apt-get install libpcre3-dev