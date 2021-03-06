
#######################################
#
# proxy.sh
#
# require prompt.sh, system.sh, replicated.sh
#
#######################################

PROXY_ADDRESS=
DID_CONFIGURE_DOCKER_PROXY=0

#######################################
# Prompts for proxy address.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   PROXY_ADDRESS
#######################################
promptForProxy() {
    printf "Does this machine require a proxy to access the Internet? "
    if ! confirmN; then
        return
    fi

    printf "Enter desired HTTP proxy address: "
    prompt
    if [ -n "$PROMPT_RESULT" ]; then
        if [ "${PROMPT_RESULT:0:7}" != "http://" ] && [ "${PROMPT_RESULT:0:8}" != "https://" ]; then
            echo >&2 "Proxy address must have prefix \"http(s)://\""
            exit 1
        fi
        PROXY_ADDRESS="$PROMPT_RESULT"
        printf "The installer will use the proxy at '%s'\n" "$PROXY_ADDRESS"
    fi
}

#######################################
# Discovers proxy address from environment.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   PROXY_ADDRESS
#######################################
discoverProxy() {
    readReplicatedConf "HttpProxy"
    if [ -n "$REPLICATED_CONF_VALUE" ]; then
        PROXY_ADDRESS="$REPLICATED_CONF_VALUE"
        printf "The installer will use the proxy at '%s' (imported from /etc/replicated.conf 'HttpProxy')\n" "$PROXY_ADDRESS"
        return
    fi

    if [ -n "$HTTP_PROXY" ]; then
        PROXY_ADDRESS="$HTTP_PROXY"
        printf "The installer will use the proxy at '%s' (imported from env var 'HTTP_PROXY')\n" "$PROXY_ADDRESS"
        return
    elif [ -n "$http_proxy" ]; then
        PROXY_ADDRESS="$http_proxy"
        printf "The installer will use the proxy at '%s' (imported from env var 'http_proxy')\n" "$PROXY_ADDRESS"
        return
    elif [ -n "$HTTPS_PROXY" ]; then
        PROXY_ADDRESS="$HTTPS_PROXY"
        printf "The installer will use the proxy at '%s' (imported from env var 'HTTPS_PROXY')\n" "$PROXY_ADDRESS"
        return
    elif [ -n "$https_proxy" ]; then
        PROXY_ADDRESS="$https_proxy"
        printf "The installer will use the proxy at '%s' (imported from env var 'https_proxy')\n" "$PROXY_ADDRESS"
        return
    fi
}

#######################################
# Requires that docker is set up with an http proxy.
# Globals:
#   DID_INSTALL_DOCKER
# Arguments:
#   None
# Returns:
#   None
#######################################
requireDockerProxy() {
    if docker info 2>/dev/null | grep -q -i "Http Proxy:"; then
        return
    fi

    _allow=n
    if [ "$DID_INSTALL_DOCKER" = "1" ]; then
        _allow=y
    else
        printf "It does not look like Docker is set up with http proxy enabled.\n"
        printf "This script will automatically configure it now.\n"
        printf "Do you want to allow this? "
        if confirmY; then
            _allow=y
        fi
    fi
    if [ "$_allow" = "y" ]; then
        configureDockerProxy
    else
        printf "Do you want to proceed anyway? "
        if ! confirmN; then
            echo >&2 "Please manually configure your Docker daemon with environment HTTP_PROXY."
            exit 1
        fi
    fi
}

#######################################
# Configures docker to run with an http proxy.
# Globals:
#   INIT_SYSTEM
#   NO_PROXY_ADDRESSES
# Arguments:
#   None
# Returns:
#   RESTART_DOCKER
#######################################
configureDockerProxy() {
    case "$INIT_SYSTEM" in
        systemd)
            if [ ! -e /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
                mkdir -p /etc/systemd/system/docker.service.d
                cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<-EOF
# File created by replicated install script
[Service]
Environment="HTTP_PROXY=$PROXY_ADDRESS" "NO_PROXY=$NO_PROXY_ADDRESSES"
EOF
                RESTART_DOCKER=1
            fi
            ;;
        upstart|sysvinit)
            _docker_conf_file=
            if [ -e /etc/sysconfig/docker ]; then
                _docker_conf_file=/etc/sysconfig/docker
            elif [ -e /etc/default/docker ]; then
                _docker_conf_file=/etc/default/docker
            else
                _docker_conf_file=/etc/default/docker
                touch $_docker_conf_file
            fi
            if ! grep -q "^export http_proxy" $_docker_conf_file; then
                cat >> $_docker_conf_file <<-EOF

# Generated by replicated install script
export http_proxy="$PROXY_ADDRESS"
export NO_PROXY="$NO_PROXY_ADDRESSES"
EOF
                RESTART_DOCKER=1
            fi
            ;;
        *)
            return 0
            ;;
    esac
    DID_CONFIGURE_DOCKER_PROXY=1
}

#######################################
# Check that the docker proxy configuration was successful.
# Globals:
#   DID_CONFIGURE_DOCKER_PROXY
# Arguments:
#   None
# Returns:
#   None
#######################################
checkDockerProxyConfig() {
    if [ "$DID_CONFIGURE_DOCKER_PROXY" != "1" ]; then
        return
    fi
    if docker info 2>/dev/null | grep -q -i "Http Proxy:"; then
        return
    fi

    echo -e "${RED}Docker proxy configuration failed.${NC}"
    printf "Do you want to proceed anyway? "
    if ! confirmN; then
        echo >&2 "Please manually configure your Docker daemon with environment HTTP_PROXY."
        exit 1
    fi
}

#######################################
# Exports proxy configuration.
# Globals:
#   PROXY_ADDRESS
# Arguments:
#   None
# Returns:
#   None
#######################################
exportProxy() {
    if [ -z "$PROXY_ADDRESS" ]; then
        return
    fi
    if [ -z "$http_proxy" ]; then
       export http_proxy=$PROXY_ADDRESS
    fi
    if [ -z "$https_proxy" ]; then
       export https_proxy=$PROXY_ADDRESS
    fi
    if [ -z "$HTTP_PROXY" ]; then
       export HTTP_PROXY=$PROXY_ADDRESS
    fi
    if [ -z "$HTTPS_PROXY" ]; then
       export HTTPS_PROXY=$PROXY_ADDRESS
    fi
}

#######################################
# Assembles a sane list of no_proxy addresses
# Globals:
#   ADDITIONAL_NO_PROXY (optional)
# Arguments:
#   None
# Returns:
#   NO_PROXY_ADDRESSES
#######################################
NO_PROXY_ADDRESSES=
getNoProxyAddresses() {
    DOCKER0_IP=$(ip -o -4 -h address | grep docker0 | awk '{ print $4 }' | cut -d'/' -f1)
    if [ -z "$DOCKER0_IP" ]; then
        DOCKER0_IP=172.17.0.1
    fi

    NO_PROXY_ADDRESSES="localhost,127.0.0.1,$DOCKER0_IP"

    if [ -n "$ADDITIONAL_NO_PROXY" ]; then
        NO_PROXY_ADDRESSES="$NO_PROXY_ADDRESSES,$ADDITIONAL_NO_PROXY"
    fi

    while [ "$#" -gt 0 ]
    do
        # [10.138.0.2]:9878 -> 10.138.0.2
        hostname=`echo $1 | sed -e 's/:[0-9]*$//' | sed -e 's/[][]//g'`
        NO_PROXY_ADDRESSES="$NO_PROXY_ADDRESSES,$hostname"
        shift
    done

    # filter duplicates
    NO_PROXY_ADDRESSES=`echo "$NO_PROXY_ADDRESSES" | sed 's/,/\n/g' | sort | uniq | paste -s --delimiters=","`
}
