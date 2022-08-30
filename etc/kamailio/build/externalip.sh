
IPV6_ENABLED=0

function getExternalIP() {
    local IPV6_ENABLED=${IPV6_ENABLED:-0}
    local EXTERNAL_IP="" TIMEOUT=5
    local URLS=() CURL_CMD="curl"

    if (( ${IPV6_ENABLED} == 1 )); then
        URLS=(
            "https://icanhazip.com"
            "https://bot.whatismyipaddress.com"
            "https://ifconfig.co"
            "https://ident.me"
            "https://api6.ipify.org"
        )
        CURL_CMD="curl -6"
        IP_TEST="ipv6Test"
    else
        URLS=(
            "https://icanhazip.com"
            "https://ipecho.net/plain"
            "https://myexternalip.com/raw"
            "https://api.ipify.org"
            "https://bot.whatismyipaddress.com"
        )
        CURL_CMD="curl -4"
        IP_TEST="ipv4Test"
    fi

    for URL in "${URLS[@]}"; do
        EXTERNAL_IP=$(${CURL_CMD} -s --connect-timeout $TIMEOUT $URL 2>/dev/null)
        ${IP_TEST} "$EXTERNAL_IP" && break
    done

    printf '%s' "$EXTERNAL_IP"
}
export -f getExternalIP

