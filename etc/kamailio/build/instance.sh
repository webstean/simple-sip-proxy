# returns: 0 == success, otherwise failure
# notes: try to access the AWS metadata URL to determine if this is an AMI instance
function isInstanceAMI() {
    curl -s -f --connect-timeout 2 http://169.254.169.254/latest/dynamic/instance-identity/ &>/dev/null
    return $?
}
export -f isInstanceAMI

# returns: 0 == success, otherwise failure
# notes: try to access the DO metadata URL to determine if this is an Digital Ocean instance
function isInstanceDO() {
    curl -s -f --connect-timeout 2 http://169.254.169.254/metadata/v1/id &>/dev/null
    return $?
}
export -f isInstanceDO

# returns: 0 == success, otherwise failure
# notes: try to access the GCE metadata URL to determine if this is an Google instance
function isInstanceGCE() {
    curl -s -f --connect-timeout 2 -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/id &>/dev/null
    return $?
}
export -f isInstanceGCE

# returns: 0 == success, otherwise failure
# notes: try to access the MS Azure metadata URL to determine if this is an Azure instance
function isInstanceAZURE() {
    curl -s -f --connect-timeout 2 -H "Metadata: true" "http://169.254.169.254/metadata/instance?api-version=2018-10-01" &>/dev/null
    return $?
}
export -f isInstanceAZURE

# returns: 0 == success, otherwise failure
# notes: try to access the DO metadata URL to determine if this is an VULTR instance
function isInstanceVULTR() {
    curl -s -f --connect-timeout 2 http://169.254.169.254/v1/instanceid &>/dev/null
    return $?
}
export -f isInstanceDO

