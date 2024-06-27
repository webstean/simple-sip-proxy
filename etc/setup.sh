#!/usr/bin/env bash

# Debug this script if in debug mode
(( $DEBUG == 1 )) && set -x

## assumes Debian 12
function mysql-install {
    ## create mysql user and group
    ## sometimes locks aren't properly removed (this seems to happen often on VM's)
    rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock &>/dev/null
    userdel mysql &>/dev/null; groupdel mysql &>/dev/null
    useradd --system --user-group --shell /bin/false --comment "Mysql Database Server" mysql

    ## install mysql packages
    apt-get install -y mariadb-server

    if (( $? != 0 )); then
        printerr 'Failed installing mariadb packages'
        return 1
    fi

    ## if db is remote don't run local service
    #reconfigureMysqlSystemdService

    ## Make sure no extra configs present on fresh install
    rm -f ~/.my.cnf

    ## ensure data directory exists
    mkdir -p /var/lib/mysql
    chown mysql:mysql /var/lib/mysql

    # TODO: selinux/apparmor permissions for mysql
    #       firewall rules (cluster install needs remote access)
    #       configure galera replication (cluster install)
    #       configure group replication (cluster install)

    # TODO: configure mysql to redirect error_log to syslog (as our other services do)
    #       https://mariadb.com/kb/en/systemd/#configuring-mariadb-to-write-the-error-log-to-syslog

    # TODO: configure logrotate to rotate syslog logs from mysql

    return 0
}

## assumes Debian 12
function kamailio-install {
    local KAM_SOURCES_LIST="/etc/apt/sources.list.d/kamailio.list"
    local KAM_PREFS_CONF="/etc/apt/preferences.d/kamailio.pref"
    local NPROC=$(nproc)
    
    # Remove ufw if installed
    apt-get remove -y ufw

    # Install Dependencies
    apt-get install -y curl wget sed gawk vim perl uuid-dev libssl-dev logrotate rsyslog \
        libcurl4-openssl-dev libjansson-dev cmake firewalld build-essential certbot

    if (( $? != 0 )); then
        printerr 'Failed installing required packages'
        return 1
    fi

    # Configure OpenSSL to a default provider
    sed -i -e 's/# providers =/providers =/' -e 's/# \[provider_sect/\[provider_sect/' -e 's/# default =/default =/' -e 's/# \[default_sect/\[default_sect/' -e 's/# activate/activate/' /etc/ssl/openssl.cnf

    # create kamailio user and group
    mkdir -p /var/run/kamailio
    # sometimes locks aren't properly removed (this seems to happen often on VM's)
    rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock &>/dev/null
    userdel kamailio &>/dev/null; groupdel kamailio &>/dev/null
    useradd --system --user-group --shell /bin/false --comment "Kamailio SIP Proxy" kamailio
    chown -R kamailio:kamailio /var/run/kamailio

    # allow root to fix permissions before starting services (required to work with SELinux enabled)
    usermod -a -G kamailio root

    # add repo sources to apt
    mkdir -p /etc/apt/sources.list.d
    (cat << EOF
# kamailio repo's
deb http://deb.kamailio.org/kamailio${KAM_VERSION} bookworm main
#deb-src http://deb.kamailio.org/kamailio${KAM_VERSION} bookworm main
EOF
    ) > ${KAM_SOURCES_LIST}

    # give higher precedence to packages from kamailio repo
    mkdir -p /etc/apt/preferences.d
    (cat << 'EOF'
Package: *
Pin: origin deb.kamailio.org
Pin-Priority: 1000
EOF
    ) > ${KAM_PREFS_CONF}

    # Add Key for Kamailio Repo
    wget -O- http://deb.kamailio.org/kamailiodebkey.gpg | apt-key add -

    # Update repo sources cache
    apt-get update -y
    
    # Install Kamailio packages
    apt-get install -y kamailio kamailio-mysql-modules kamailio-extra-modules \
        kamailio-tls-modules kamailio-websocket-modules kamailio-presence-modules \
        kamailio-json-modules

    # get info about the kamailio install for later use in script
    KAM_VERSION_FULL=$(kamailio -v 2>/dev/null | grep '^version:' | awk '{print $3}')
    KAM_MODULES_DIR=$(find /usr/lib{32,64,}/{i386*/*,i386*/kamailio/*,x86_64*/*,x86_64*/kamailio/*,*} -name drouting.so -printf '%h' -quit 2>/dev/null)

    # create kamailio defaults config
    cp -f kamailio.conf /etc/default/kamailio.conf
    # create kamailio tmp files
    echo "d /run/kamailio 0750 kamailio kamailio" > /etc/tmpfiles.d/kamailio.conf

    # Configure Kamailio and Required Database Modules
    mkdir -p ${SYSTEM_KAMAILIO_CONFIG_DIR} ${BACKUPS_DIR}/kamailio
    mv -f ${SYSTEM_KAMAILIO_CONFIG_DIR}/kamctlrc ${BACKUPS_DIR}/kamailio/kamctlrc.$(date +%Y%m%d_%H%M%S)
    if [[ -z "${ROOT_DB_PASS-unset}" ]]; then
        local ROOTPW_SETTING="DBROOTPWSKIP=yes"
    else
        local ROOTPW_SETTING="DBROOTPW=\"${ROOT_DB_PASS}\""
    fi

    # TODO: we should set STORE_PLAINTEXT_PW to 0, this is not default but would need tested
    (cat << EOF
DBENGINE=MYSQL
DBHOST="${KAM_DB_HOST}"
DBPORT="${KAM_DB_PORT}"
DBNAME="${KAM_DB_NAME}"
DBROUSER="${KAM_DB_USER}"
DBROPW="${KAM_DB_PASS}"
DBRWUSER="${KAM_DB_USER}"
DBRWPW="${KAM_DB_PASS}"
DBROOTHOST="${ROOT_DB_HOST}"
DBROOTPORT="${ROOT_DB_PORT}"
DBROOTUSER="${ROOT_DB_USER}"
${ROOTPW_SETTING}
CHARSET=utf8
INSTALL_EXTRA_TABLES=yes
INSTALL_PRESENCE_TABLES=yes
INSTALL_DBUID_TABLES=yes
#STORE_PLAINTEXT_PW=0
EOF
    ) > ${SYSTEM_KAMAILIO_CONFIG_DIR}/kamctlrc

    # in mariadb ver >= 10.6.1 --port= now defaults to transport=tcp
    # we want socket connections for root as default so apply our patch to kamdbctl
    (
        cd /usr/lib/x86_64-linux-gnu/kamailio/kamctl &&
        patch -p3 -N <${DSIP_PROJECT_DIR}/kamailio/debian/kamdbctl.patch
    )
    if (( $? > 1 )); then
        printerr 'Failed patching kamdbctl'
        return 1
    fi

    # Execute 'kamdbctl create' to create the Kamailio database schema
    kamdbctl create || {
        printerr 'Failed creating kamailio database'
        return 1
    }

    # Enable and start firewalld if not already running
    systemctl enable firewalld

    # Setup firewall rules
    firewall-cmd --zone=public --add-port=${KAM_SIP_PORT}/udp --permanent
    firewall-cmd --zone=public --add-port=${KAM_SIP_PORT}/tcp --permanent
    firewall-cmd --zone=public --add-port=${KAM_SIPS_PORT}/tcp --permanent
    firewall-cmd --zone=public --add-port=${KAM_WSS_PORT}/tcp --permanent
    firewall-cmd --zone=public --add-port=${KAM_DMQ_PORT}/udp --permanent
    firewall-cmd --zone=public --add-port=22/tcp --permanent
    firewall-cmd --reload

    systemctl start firewalld

    # Configure Kamailio systemd service
    cp -f ${DSIP_PROJECT_DIR}/kamailio/systemd/kamailio-v2.service /lib/systemd/system/kamailio.service
    chmod 644 /lib/systemd/system/kamailio.service
    systemctl daemon-reload
    systemctl enable kamailio

    # Configure rsyslog defaults
    if ! grep -q 'dSIPRouter rsyslog.conf' /etc/rsyslog.conf 2>/dev/null; then
        cp -f ${DSIP_PROJECT_DIR}/resources/syslog/rsyslog.conf /etc/rsyslog.conf
    fi

    # Setup kamailio Logging
    cp -f ${DSIP_PROJECT_DIR}/resources/syslog/kamailio.conf /etc/rsyslog.d/kamailio.conf
    touch /var/log/kamailio.log
    systemctl restart rsyslog

    # Setup logrotate
    cp -f ${DSIP_PROJECT_DIR}/resources/logrotate/kamailio /etc/logrotate.d/kamailio

    # Setup Kamailio to use the CA cert's that are shipped with the OS
    mkdir -p ${DSIP_SYSTEM_CONFIG_DIR}/certs/stirshaken
    ln -s /etc/ssl/certs/ca-certificates.crt ${DSIP_SSL_CA}
    updateCACertsDir

    # setup STIR/SHAKEN module for kamailio
    ## compile and install libjwt (version in repos is too old)
    if [[ ! -d ${SRC_DIR}/libjwt ]]; then
        git clone --depth 1 -c advice.detachedHead=false https://github.com/benmcollins/libjwt.git ${SRC_DIR}/libjwt
    fi
    (
        cd ${SRC_DIR}/libjwt &&
        autoreconf -i &&
        ./configure --prefix=/usr &&
        make -j $NPROC &&
        make -j $NPROC install
    ) || {
        printerr 'Failed to compile and install libjwt'
        return 1
    }

    ## compile and install libks
    if [[ ! -d ${SRC_DIR}/libks ]]; then
        git clone --single-branch -c advice.detachedHead=false https://github.com/signalwire/libks -b v1.8.3 ${SRC_DIR}/libks
    fi
    (
        cd ${SRC_DIR}/libks &&
        cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release . &&
        make -j $NPROC &&
        make -j $NPROC install
    ) || {
        printerr 'Failed to compile and install libks'
        return 1
    }

    ## compile and install libstirshaken
    if [[ ! -d ${SRC_DIR}/libstirshaken ]]; then
        git clone --depth 1 -c advice.detachedHead=false https://github.com/signalwire/libstirshaken ${SRC_DIR}/libstirshaken
    fi
    (
        # TODO: commit updates to upstream to fix EVP_PKEY_cmp being deprecated
        cd ${SRC_DIR}/libstirshaken &&
        ./bootstrap.sh &&
        ./configure --prefix=/usr &&
        make -j $NPROC CFLAGS='-Wno-deprecated-declarations' &&
        make -j $NPROC install &&
        ldconfig
    ) || {
        printerr 'Failed to compile and install libstirshaken'
        return 1
    }

    ## compile and install STIR/SHAKEN module
    ## reuse repo if it exists and matches version we want to install
    if [[ -d ${SRC_DIR}/kamailio ]]; then
        if [[ "$(getGitTagFromShallowRepo ${SRC_DIR}/kamailio)" != "${KAM_VERSION_FULL}" ]]; then
            rm -rf ${SRC_DIR}/kamailio
            git clone --depth 1 -c advice.detachedHead=false -b ${KAM_VERSION_FULL} https://github.com/kamailio/kamailio.git ${SRC_DIR}/kamailio
        fi
    else
        git clone --depth 1 -c advice.detachedHead=false -b ${KAM_VERSION_FULL} https://github.com/kamailio/kamailio.git ${SRC_DIR}/kamailio
    fi
    (
        cd ${SRC_DIR}/kamailio/src/modules/stirshaken &&
        make -j $NPROC
    ) &&
    cp -f ${SRC_DIR}/kamailio/src/modules/stirshaken/stirshaken.so ${KAM_MODULES_DIR}/ || {
        printerr 'Failed to compile and install STIR/SHAKEN module'
        return 1
    }

    return 0
}






==============================
# NOTES:
# contains utility functions and shared variables
# should be sourced by an external script
# exporting upon import removes need to import again in sub-processes

######################
# Imported Constants #
######################

# Ansi Colors
export ESC_SEQ="\033["
export ANSI_NONE="${ESC_SEQ}39;49;00m" # Reset colors
export ANSI_RED="${ESC_SEQ}1;31m"
export ANSI_GREEN="${ESC_SEQ}1;32m"
export ANSI_YELLOW="${ESC_SEQ}1;33m"
export ANSI_CYAN="${ESC_SEQ}1;36m"
export ANSI_WHITE="${ESC_SEQ}1;37m"

##############################################
# Printing functions and String Manipulation #
##############################################

# checks if stdin is null and sets STDIN_FIRST_BYTE to first character of stdin
function isStdinNull() {
    local c
    read -r -d '' c
}

function printbold() {
    if [[ "$1" == "-n" ]]; then
        shift; printf "%b%s%b" "${ANSI_WHITE}" "$*" "${ANSI_NONE}"
    else
        printf "%b%s%b\n" "${ANSI_WHITE}" "$*" "${ANSI_NONE}"
    fi
}
export -f printbold

function printerr() {
    if [[ "$1" == "-n" ]]; then
        shift; printf "%b%s%b" "${ANSI_RED}" "$*" "${ANSI_NONE}"
    else
        printf "%b%s%b\n" "${ANSI_RED}" "$*" "${ANSI_NONE}"
    fi
}
export -f printerr

function printwarn() {
    if [[ "$1" == "-n" ]]; then
        shift; printf "%b%s%b" "${ANSI_YELLOW}" "$*" "${ANSI_NONE}"
    else
        printf "%b%s%b\n" "${ANSI_YELLOW}" "$*" "${ANSI_NONE}"
    fi
}
export -f printwarn

function printdbg() {
    if [[ "$1" == "-n" ]]; then
        shift; printf "%b%s%b" "${ANSI_GREEN}" "$*" "${ANSI_NONE}"
    else
        printf "%b%s%b\n" "${ANSI_GREEN}" "$*" "${ANSI_NONE}"
    fi
}
export -f printdbg

function pprint() {
    if [[ "$1" == "-n" ]]; then
        shift; printf "%b%s%b" "${ANSI_CYAN}" "$*" "${ANSI_NONE}"
    else
        printf "%b%s%b\n" "${ANSI_CYAN}" "$*" "${ANSI_NONE}"
    fi
}
export -f pprint

function tolower() {
    [[ -p /dev/stdin ]] &&
    (
        read -r -d '' INPUT
        [[ -z "$INPUT" ]] && exit 1
        tr '[ABCDEFGHIJKLMNOPQRSTUVWXYZ]' '[abcdefghijklmnopqrstuvwxyz]' <<<"$INPUT"
        exit 0
    ) ||
    {
        printf '%s' "$1" | tr '[ABCDEFGHIJKLMNOPQRSTUVWXYZ]' '[abcdefghijklmnopqrstuvwxyz]'
    }
}
export -f tolower

function toupper() {
    [[ -p /dev/stdin ]] &&
    (
        read -r -d '' INPUT
        [[ -z "$INPUT" ]] && exit 1
        tr '[abcdefghijklmnopqrstuvwxyz]' '[ABCDEFGHIJKLMNOPQRSTUVWXYZ]' <<<"$INPUT"
        exit 0
    ) ||
    {
        printf '%s' "$1" | tr '[abcdefghijklmnopqrstuvwxyz]' '[ABCDEFGHIJKLMNOPQRSTUVWXYZ]'
    }
}
export -f toupper

function hextoint() {
    [[ -p /dev/stdin ]] &&
    (
        read -r -d '' INPUT
        [[ -z "$INPUT" ]] && exit 1
        printf '%d' "0x$INPUT" 2>/dev/null
        exit 0
    ) ||
    {
        printf '%d' "0x$1" 2>/dev/null
    }
}
export -f hextoint

######################################
# Traceback / Debug helper functions #
######################################

function backtrace() {
    local DEPTN=${#FUNCNAME[@]}

    for ((i=1; i < ${DEPTN}; i++)); do
        local FUNC="${FUNCNAME[$i]}"
        local LINE="${BASH_LINENO[$((i-1))]}"
        local SRC="${BASH_SOURCE[$((i-1))]}"
        printf '%*s' $i '' # indent
        printerr "[ERROR]: ${FUNC}(), ${SRC}, line: ${LINE}"
    done
}
export -f backtrace

function setErrorTracing() {
    set -o errtrace
    trap 'backtrace' ERR
}
export -f setErrorTracing

# public IP's us for testing / DNS lookups in scripts
export GOOGLE_DNS_IPV4="8.8.8.8"
export GOOGLE_DNS_IPV6="2001:4860:4860::8888"

# Constants for imported functions
export DSIP_INIT_FILE=${DSIP_INIT_FILE:-"/lib/systemd/system/dsip-init.service"}
export DSIP_SYSTEM_CONFIG_DIR=${DSIP_SYSTEM_CONFIG_DIR:-"/etc/dsiprouter"}
export DSIP_PROJECT_DIR=${DSIP_PROJECT_DIR:-$(dirname $(dirname $(readlink -f "$BASH_SOURCE")))}



#######################################
# Reusable / Shared Utility functions #
#######################################

# TODO: we need to change the config getter/setter functions to use options parsing:
# - when the value to set variable to is the empty string our functions error out
# - ordering of filename and other options can be easily mistaken, which can set wrong values in config
# - input validation would also be much easier if we switched added option parsing

# $1 == attribute name
# $2 == attribute value
# $3 == python config file
# $4 == -q (quote string) | -qb (quote byte string)
function setConfigAttrib() {
    local NAME="$1"
    local VALUE="$2"
    local CONFIG_FILE="$3"

    if (( $# >= 4 )); then
        if [[ "$4" == "-q" ]]; then
            VALUE="'${VALUE}'"
        elif [[ "$4" == "-qb" ]]; then
            VALUE="b'${VALUE}'"
        fi
    fi
    sed -i -r -e "s|$NAME[ \t]*=[ \t]*.*|$NAME = $VALUE|g" ${CONFIG_FILE}
}
export -f setConfigAttrib


# $1 == attribute name
# $2 == kamailio config file
function enableKamailioConfigAttrib() {
    local NAME="$1"
    local CONFIG_FILE="$2"

    sed -i -r -e "s~#+(!(define|trydef|redefine)[[:space:]]? $NAME)~#\1~g" ${CONFIG_FILE}
}
export -f enableKamailioConfigAttrib

# $1 == attribute name
# $2 == kamailio config file
function disableKamailioConfigAttrib() {
    local NAME="$1"
    local CONFIG_FILE="$2"

    sed -i -r -e "s~#+(!(define|trydef|redefine)[[:space:]]? $NAME)~##\1~g" ${CONFIG_FILE}
}
export -f disableKamailioConfigAttrib

# $1 == name of defined url to change
# $2 == value to change url to
# $3 == kamailio config file
# notes: will skip any cluster url attributes
function setKamailioConfigDburl() {
    local NAME="$1"
    local VALUE="$2"
    local CONFIG_FILE="$3"

    perl -e "\$dburl='${VALUE}';" \
        -0777 -i -pe 's~(#!(define|trydef|redefine)\s+?'"${NAME}"'\s+)['"'"'"](?!cluster\:).*['"'"'"]~\1"${dburl}"~g' ${CONFIG_FILE}
}
export -f setKamailioConfigDburl

# $1 == name of subst/substdef/substdefs to change
# $2 == value to change subst/substdef/substdefs to
# $3 == kamailio config file
function setKamailioConfigSubst() {
    local NAME="$1"
    local VALUE="$2"
    local CONFIG_FILE="$3"

    perl -e "\$name='$NAME'; \$value='$VALUE';" \
        -i -pe 's~(#!subst(?:def|defs)?.*!${name}!).*(!.*)~\1${value}\2~g' ${CONFIG_FILE}
}
export -f setKamailioConfigSubst

# $1 == name of global variable to change
# $2 == value to change variable to
# $3 == kamailio config file
function setKamailioConfigGlobal() {
    local NAME="$1"
    local VALUE="$2"
    local CONFIG_FILE="$3"
    local REPLACE_TOKEN='__ABCDEFGHIJKLMNOPQRSTUVWXYZ__'

    perl -pi -e "s~^(${NAME}\s?=\s?)(?:(\"|')(.*?)(\"|')|\d+)(\sdesc\s(?:\"|').*?(?:\"|'))?~\1\2${REPLACE_TOKEN}\4\5~g" ${CONFIG_FILE}
    sed -i -e "s%${REPLACE_TOKEN}%${VALUE}%g" ${CONFIG_FILE}
}
export -f setKamailioConfigGlobal

# $1 == attribute name
# $2 == rtpengine config file
function enableRtpengineConfigAttrib() {
    local NAME="$1"
    local CONFIG_FILE="$2"

    sed -i -r -e "s~^#+(${NAME}[ \t]*=[ \t]*.*)~\1~g" ${CONFIG_FILE}
}
export -f enableRtpengineConfigAttrib

# $1 == attribute name
# $2 == rtpengine config file
function disableRtpengineConfigAttrib() {
    local NAME="$1"
    local CONFIG_FILE="$2"

    sed -i -r -e "s~^#*(${NAME}[ \t]*=[ \t]*.*)~#\1~g" ${CONFIG_FILE}
}
export -f disableRtpengineConfigAttrib

# $1 == attribute name
# $2 == rtpengine config file
function getRtpengineConfigAttrib() {
    local NAME="$1"
    local CONFIG_FILE="$2"

    grep -oP '^(?!#)('${NAME}'[ \t]*=[ \t]*\K.*)' ${CONFIG_FILE}
}
export -f getRtpengineConfigAttrib

# $1 == attribute name
# $2 == value of attribute
# $3 == rtpengine config file
function setRtpengineConfigAttrib() {
    local NAME="$1"
    local VALUE="$2"
    local CONFIG_FILE="$3"

    perl -e "\$name='$NAME'; \$value='$VALUE';" \
        -i -pe 's%^(?!#)(${name}[ \t]*=[ \t]*.*)%${name} = ${value}%g' ${CONFIG_FILE}
}
export -f setRtpengineConfigAttrib

# output: Linux Distro name
function getDistroName() {
    grep '^ID=' /etc/os-release 2>/dev/null | cut -d '=' -f 2 | cut -d '"' -f 2
}
export -f getDistroName

# output: Linux Distro version
function getDistroVer() {
    grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d '=' -f 2 | cut -d '"' -f 2
}
export -f getDistroVer

# $1 == command to test
# returns: 0 == true, 1 == false
function cmdExists() {
    if command -v "$1" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}
export -f cmdExists

# $1 == directory to check for in PATH
# returns: 0 == found, 1 == not found
function pathCheck() {
    case ":${PATH-}:" in
        *:"$1":*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
export -f pathCheck

# returns: 0 == success, otherwise failure
# notes: try to access the MS Azure metadata URL to determine if this is an Azure instance
function isInstanceAZURE() {
    curl -s -f --connect-timeout 2 -H "Metadata: true" "http://169.254.169.254/metadata/instance?api-version=2018-10-01" &>/dev/null
    return $?
}
export -f isInstanceAZURE

# $1 == crontab entry to append
function cronAppend() {
    local ENTRY="$1"
    crontab -l 2>/dev/null | { cat; echo "$ENTRY"; } | crontab -
}
export -f cronAppend

# $1 == crontab entry to remove
function cronRemove() {
    local ENTRY="$1"
    crontab -l 2>/dev/null | grep -v -F -w "$ENTRY" | crontab -
}
export -f cronRemove

# $1 == ip to test
# returns: 0 == success, 1 == failure
# notes: regex credit to <https://helloacm.com>
function ipv4Test() {
    local IP="$1"

    if [[ $IP =~ ^([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then
        return 0
    fi
    return 1
}
export -f ipv4Test

# $1 == ip to test
# returns: 0 == success, 1 == failure
# notes: regex credit to <https://helloacm.com>
function ipv6Test() {
    local IP="$1"

    if [[ $IP =~ ^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$ ]]; then
        return 0
    fi
    return 1
}
export -f ipv6Test

# $1 == [-4|-6] to force specific IP version
# output: the internal IP for this system
# notes: prints internal ip, or empty string if not available
# notes: tries ipv4 first then ipv6
# TODO: currently we only check for the internal IP associated with the default interface/default route
#       this will fail if the internal IP is not assigned to the default interface/default route
#       not sure what networking scenarios that would be useful for, the community should provide us feedback on this
function getInternalIP() {
    local INTERNAL_IP=""

    case "$1" in
        -4)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=0
            ;;
        -6)
            local IPV4_ENABLED=0
            local IPV6_ENABLED=1
            ;;
        *)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=${IPV6_ENABLED:-0}
            ;;
    esac
	    
    if (( ${IPV6_ENABLED} == 1 )); then
		INTERFACE=$(ip -br -6 a| grep UP | head -1 | awk {'print $1'})
    else
		INTERFACE=$(ip -4 route show default | head -1 | awk '{print $5}')
    fi

    # Get the ip address without depending on DNS
    if (( ${IPV4_ENABLED} == 1 )); then
        # Marked for removal because it depends on DNS
		#INTERNAL_IP=$(ip -4 route get $GOOGLE_DNS_IPV4 2>/dev/null | head -1 | grep -oP 'src \K([^\s]+)')
		INTERNAL_IP=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -f1 -d'/' | head -1)
    fi

    if (( ${IPV6_ENABLED} == 1 )) && [[ -z "$INTERNAL_IP" ]]; then
        # Marked for removal because it depends on DNS
        #INTERNAL_IP=$(ip -6 route get $GOOGLE_DNS_IPV6 2>/dev/null | head -1 | grep -oP 'src \K([^\s]+)')
		INTERNAL_IP=$(ip addr show $INTERFACE | grep 'inet6 ' | awk '{print $2}' | cut -f1 -d'/' | head -1)
    fi

    printf '%s' "$INTERNAL_IP"
}
export -f getInternalIP

# $1 == [-4|-6] to force specific IP version
# $2 == network interface 
# output: the IP for the given interface
# notes: prints ip, or empty string if not available
# notes: tries ipv4 first then ipv6
function getIP() {
    local IP=""

    case "$1" in
        -4)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=0
            ;;
        -6)
            local IPV4_ENABLED=0
            local IPV6_ENABLED=1
            ;;
        *)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=${IPV6_ENABLED:-0}
            ;;
    esac

    # Use the provided interface or get the first interface - other then lo
    if ! [ -z $2 ]; then
	    INTERFACE=$2
    else
	    if (( ${IPV6_ENABLED} == 1 )); then
			INTERFACE=$(ip -br -6 a| grep UP | head -1 | awk {'print $1'})
	    else
	    	INTERFACE=$(ip -4 route show default | head -1 | awk '{print $5}')
	    fi
    fi

    # Get the ip address without depending on DNS
    if (( ${IPV4_ENABLED} == 1 )); then
        # Marked for removal because it depends on DNS
		#INTERNAL_IP=$(ip -4 route get $GOOGLE_DNS_IPV4 2>/dev/null | head -1 | grep -oP 'src \K([^\s]+)')
		IP=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -f1 -d'/' | head -1)
    fi

    if (( ${IPV6_ENABLED} == 1 )) && [[ -z "$INTERNAL_IP" ]]; then
        # Marked for removal because it depends on DNS
        #INTERNAL_IP=$(ip -6 route get $GOOGLE_DNS_IPV6 2>/dev/null | head -1 | grep -oP 'src \K([^\s]+)')
		IP=$(ip addr show $INTERFACE | grep 'inet6 ' | awk '{print $2}' | cut -f1 -d'/' | head -1)
    fi

    printf '%s' "$IP"
}
export -f getIP

# TODO: run requests in parallel and grab first good one (start ipv4 first)
#       this is what we are already doing in gui/util/networking.py
#       this would be much faster bcuz DNS exceptions take a while to handle
#       GNU parallel should not be used bcuz package support is not very good
#       this should instead use a pure bash version of GNU parallel, refs:
#       https://stackoverflow.com/questions/10909685/run-parallel-multiple-commands-at-once-in-the-same-terminal
#       https://www.cyberciti.biz/faq/how-to-run-command-or-code-in-parallel-in-bash-shell-under-linux-or-unix/
#       https://unix.stackexchange.com/questions/305039/pausing-a-bash-script-until-previous-commands-are-finished
#       https://unix.stackexchange.com/questions/497614/bash-execute-background-process-whilst-reading-output
#       https://stackoverflow.com/questions/3338030/multiple-bash-traps-for-the-same-signal
# $1 == [-4|-6] to force specific IP version
# output: the external IP for this system
# notes: prints external ip, or empty string if not available
# notes: below we have measurements for average time of each service
#        over 10 non-cached requests, in seconds, round trip
#
# |          External Service         | Mean RTT | IP Protocol |
# |:---------------------------------:|:--------:|:-----------:|
# | https://icanhazip.com             | 0.38080  | IPV4        |
# | https://ipecho.net/plain          | 0.39810  | IPV4        |
# | https://myexternalip.com/raw      | 0.51850  | IPV4        |
# | https://api.ipify.org             | 0.64860  | IPV4        |
# | https://bot.whatismyipaddress.com | 0.69640  | IPV4        |
# | https://icanhazip.com             | 0.40190  | IPV6        |
# | https://bot.whatismyipaddress.com | 0.72490  | IPV6        |
# | https://ifconfig.co               | 0.80290  | IPV6        |
# | https://ident.me                  | 0.97620  | IPV6        |
# | https://api6.ipify.org            | 1.08510  | IPV6        |
#
function getExternalIP() {
    local EXTERNAL_IP="" TIMEOUT=5
    local IPV4_URLS=(
        "https://icanhazip.com"
        "https://ipecho.net/plain"
        "https://myexternalip.com/raw"
        "https://api.ipify.org"
        "https://bot.whatismyipaddress.com"
    )
    local IPV6_URLS=(
        "https://icanhazip.com"
        "https://bot.whatismyipaddress.com"
        "https://ifconfig.co"
        "https://ident.me"
        "https://api6.ipify.org"
    )

    case "$1" in
        -4)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=0
            ;;
        -6)
            local IPV4_ENABLED=0
            local IPV6_ENABLED=1
            ;;
        *)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=${IPV6_ENABLED:-0}
            ;;
    esac

    if (( ${IPV4_ENABLED} == 1 )); then
        for URL in ${IPV4_URLS[@]}; do
            EXTERNAL_IP=$(curl -4 -s --connect-timeout $TIMEOUT $URL 2>/dev/null)
            ipv4Test "$EXTERNAL_IP" && { printf '%s' "$EXTERNAL_IP"; return 0; }
        done
    fi

    if (( ${IPV6_ENABLED} == 1 )) && [[ -z "$EXTERNAL_IP" ]]; then
        for URL in ${IPV6_URLS[@]}; do
            EXTERNAL_IP=$(curl -6 -s --connect-timeout $TIMEOUT $URL 2>/dev/null)
            ipv6Test "$EXTERNAL_IP" && { printf '%s' "$EXTERNAL_IP"; return 0; }
        done
    fi

    return 1
}
export -f getExternalIP

# output: the internal FQDN for this system
# notes: prints internal FQDN, or empty string if not available
function getInternalFQDN() {
    printf '%s' "$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
}
export -f getInternalFQDN

# output: the external FQDN for this system
# notes: prints external FQDN, or empty string if not available
# notes: will use EXTERNAL_IP if available or look it up dynamically
# notes: tries ipv4 first then ipv6
function getExternalFQDN() {
    local EXTERNAL_FQDN=$(dig @${GOOGLE_DNS_IPV4} +short -x ${EXTERNAL_IP:-$(getExternalIP -4)} 2>/dev/null | head -1 | sed 's/\.$//')
    if (( ${IPV6_ENABLED:-0} == 1 )) && [[ -z "$EXTERNAL_FQDN" ]]; then
          EXTERNAL_FQDN=$(dig @${GOOGLE_DNS_IPV6} +short -x ${EXTERNAL_IP6:-$(getExternalIP -6)} 2>/dev/null | head -1 | sed 's/\.$//')
    fi
    printf '%s' "$EXTERNAL_FQDN"
}
export -f getExternalFQDN

# $1 == [-4|-6] to force specific IP version
# $2 == interface
# output: the internal IP CIDR for this system
# notes: prints internal CIDR address, or empty string if not available
# notes: tries ipv4 first then ipv6
function getInternalCIDR() {
    local PREFIX_LEN="" DEF_IFACE="" INTERNAL_IP=""
    #local IP=$(ip -4 route get $GOOGLE_DNS_IPV4 2>/dev/null | head -1 | grep -oP 'src \K([^\s]+)')

    case "$1" in
        -4)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=0
            ;;
        -6)
            local IPV4_ENABLED=0
            local IPV6_ENABLED=1
            ;;
        *)
            local IPV4_ENABLED=1
            local IPV6_ENABLED=${IPV6_ENABLED:-0}
            ;;
    esac
    
    if ! [ -z $2 ]; then
	    INTERFACE=$2
    fi

    if (( ${IPV4_ENABLED} == 1 )); then
        INTERNAL_IP=$(getIP -4 "$INTERFACE")
        if [[ -n "$INTERNAL_IP" ]]; then
			if [[ -n "$INTERFACE" ]]; then
				DEF_IFACE=$INTERFACE
			else
				DEF_IFACE=$(ip -4 route list scope global 2>/dev/null | perl -e 'while (<>) { if (s%^(?:0\.0\.0\.0|default).*dev (\w+).*$%\1%) { print; exit; } }')
			fi
			PREFIX_LEN=$(ip -4 route list | grep "$INTERNAL_IP" | perl -e 'while (<>) { if (s%^(?!0\.0\.0\.0|default).*/(\d+) .*src [\w/.]*.*$%\1%) { print; exit; } }')
        fi
    fi

    if (( ${IPV6_ENABLED} == 1 )) && [[ -z "$INTERNAL_IP" ]]; then
        INTERNAL_IP=$(getInternalIP -6)
        if [[ -n "$INTERNAL_IP" ]]; then
            DEF_IFACE=$(ip -6 route list scope global 2>/dev/null | perl -e 'while (<>) { if (s%^(?:::/0|default).*dev (\w+).*$%\1%) { print; exit; } }')
            PREFIX_LEN=$(ip -6 route list 2>/dev/null | grep "dev $DEF_IFACE" | perl -e 'while (<>) { if (s%^(?!::/0|default).*/(\d+) .*via [\w:/.]*.*$%\1%) { print; exit; } }')
        fi
    fi

    # make sure output is empty if error occurred
    if [[ -n "$INTERNAL_IP" && -n "$PREFIX_LEN" ]]; then
        printf '%s/%s' "$INTERNAL_IP" "$PREFIX_LEN"
    fi
}
export -f getInternalCIDR

# $1 == cmd as executed in systemd (by ExecStart=)
# notes: take precaution when adding long running functions as they will block startup in boot order
# notes: adding init commands on an AMI instance must not be long running processes, otherwise they will fail
function addInitCmd() {
    local CMD=$(printf '%s' "$1" | sed -e 's|[\/&]|\\&|g') # escape string
    local TMP_FILE="${DSIP_INIT_FILE}.tmp"

    # sanity check, does the entry already exist?
    grep -q -oP "^ExecStart\=.*${CMD}.*" 2>/dev/null ${DSIP_INIT_FILE} && return 0

    tac ${DSIP_INIT_FILE} | sed -r "0,\|^ExecStart\=.*|{s|^ExecStart\=.*|ExecStart=${CMD}\n&|}" | tac > ${TMP_FILE}
    mv -f ${TMP_FILE} ${DSIP_INIT_FILE}

    systemctl daemon-reload
}
export -f addInitCmd

# $1 == string to match for removal (after ExecStart=)
function removeInitCmd() {
    local STR=$(printf '%s' "$1" | sed -e 's|[\/&]|\\&|g') # escape string

    sed -i -r "\|^ExecStart\=.*${STR}.*|d" ${DSIP_INIT_FILE}
    systemctl daemon-reload
}
export -f removeInitCmd

# $1 == service name (full name with target) to add dependency on dsip-init service
# notes: only adds startup ordering dependency (service continues if init fails)
# notes: the Before= section of init will link to an After= dependency on daemon-reload
function addDependsOnInit() {
    local SERVICE="$1"

    # sanity check, does the entry already exist?
    grep -q -oP "^(Before\=|Wants\=).*${SERVICE}.*" 2>/dev/null ${DSIP_INIT_FILE} && return 0

    perl -i -e "\$service='$SERVICE';" -pe 's%^(Before\=|Wants\=)(.*)%length($2)==0 ? "${1}${service}" : "${1}${2} ${service}"%ge;' ${DSIP_INIT_FILE}
    systemctl daemon-reload
}
export -f addDependsOnInit

# $1 == service name (full name with target) to remove dependency on dsip-init service
function removeDependsOnInit() {
    local SERVICE="$1"

    perl -i -e "\$service='$SERVICE';" -pe 's%^((?:Before\=|Wants\=).*?)( ${service}|${service} |${service})(.*)%\1\3%g;' ${DSIP_INIT_FILE}
    systemctl daemon-reload
}
export -f removeDependsOnInit

# $1 == ip or hostname
# $2 == port (optional)
# returns: 0 == connection good, 1 == connection bad
# NOTE: if port is not given a ping test will be used instead
function checkConn() {
    local TIMEOUT=3 IP_ADDR="" PING_V6_SELECTOR=""

    if (( $# == 2 )); then
        timeout $TIMEOUT bash -c "< /dev/tcp/$1/$2" &>/dev/null; return $?
    else
        # NOTE: older versions of ping don't automatically detect IP address version
        IP_ADDR=$(getent hosts "$1" 2>/dev/null | awk '{ print $1 ; exit }')
        if ipv6Test "$IP_ADDR"; then
            PING_V6_SELECTOR="-6"
        fi
        ping $PING_V6_SELECTOR -q -W $TIMEOUT -c 3 "$1" &>/dev/null; return $?
    fi
}
export -f checkConn

# $@ == ssh command to test
# returns: 0 == ssh connected, 1 == ssh could not connect
function checkSSH() {
    $@ -o ConnectTimeout=5 'exit 0' &>/dev/null
    return $?
}
export -f checkSSH

# bake in the connection details for kamailio user/database
# standardizes our usage and avoids various pitfalls with the client APIs
# usage:    withKamDB <mysql cmd> [mysql options/args]
function withKamDB() {
    local CONN_OPTS=()
    local CMD="$1"
    shift

    [[ -n "$KAM_DB_HOST" ]] && CONN_OPTS+=( "--host=${KAM_DB_HOST}" )
    [[ -n "$KAM_DB_PORT" ]] && CONN_OPTS+=( "--port=${KAM_DB_PORT}" )
    [[ -n "$KAM_DB_USER" ]] && CONN_OPTS+=( "--user=${KAM_DB_USER}" )
    [[ -n "$KAM_DB_PASS" ]] && CONN_OPTS+=( "--password=${KAM_DB_PASS}" )
    if [[ "$1" == "mysql" ]]; then
        [[ -n "$KAM_DB_NAME" ]] && CONN_OPTS+=( "--database=${KAM_DB_NAME}" )
    fi

    if [[ -p /dev/stdin ]]; then
        ${CMD} "${CONN_OPTS[@]}" "$@" </dev/stdin
    else
        ${CMD} "${CONN_OPTS[@]}" "$@"
    fi
    return $?
}
export -f withKamDB

# usage:    urandomChars [options] [args]
# options:  -f <filter> == characters to allow
# args:     $1 == number of characters to get
# output:   string of random printable characters
function urandomChars() {
	local LEN=32 FILTER="a-zA-Z0-9"

    while (( $# > 0 )); do
    	# last arg is length
        if (( $# == 1 )); then
            LEN="$1"
            shift
            break
        fi

        case "$1" in
        	# user defined filter
            -f)
                shift
                FILTER="$1"
                shift
                ;;
			# not valid option skip
            *)
                shift
                ;;
        esac
    done

    tr -dc "$FILTER" </dev/urandom | dd if=/dev/stdin of=/dev/stdout bs=1 count="$LEN" 2>/dev/null
}
export -f urandomChars

# $1 == prefix for each arg
# $2 == delimiter between args
# $3 == suffix for each arg
# $@ == args to join
function joinwith() {
    local START="$1" IFS="$2" END="$3" ARR=()
    shift;shift;shift

    for VAR in "$@"; do
        ARR+=("${START}${VAR}${END}")
    done

    echo "${ARR[*]}"
}
export -f joinwith

# $1 == rpc command
# $@ == rpc args
# output: output returned from kamailio
# returns: curl return code (ref: man 1 curl)
# note: curl will timeout after 3 seconds
function sendKamCmd() {
    local CMD="$1" PARAMS="" KAM_API_URL='http://127.0.0.1:5060/api/kamailio'
    shift
    local ARGS=("$@")

    if [[ "$CMD" == "cfg.seti" ]]; then
        local LAST_ARG="${ARGS[$#-1]}"
        unset "ARGS[$#-1]"
        PARAMS='['$(joinwith '"' ',' '"' "${ARGS[@]}")",${LAST_ARG}"']'
    else
        PARAMS='['$(joinwith '"' ',' '"' "$@")']'
    fi

    curl -s -m 3 -X GET -d '{"method": "'"${CMD}"'", "jsonrpc": "2.0", "id": 1, "params": '"${PARAMS}"'}' ${KAM_API_URL}
}
export -f sendKamCmd

# $1 == repo path
function getGitTagFromShallowRepo() { (
    cd "$1" 2>/dev/null &&
    git config --get remote.origin.fetch | cut -d ':' -f 2- | rev | cut -d '/' -f 1 | rev
) }
export -f getGitTagFromShallowRepo

==============================



