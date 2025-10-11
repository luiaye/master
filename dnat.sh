#!/bin/bash
# Dynamic DNAT 管理 - 图形化菜单版
set -euo pipefail

BASE=/etc/dnat
CONF=$BASE/conf
mkdir -p $BASE
touch $CONF

red="\033[31m"
green="\033[32m"
yellow="\033[33m"
black="\033[0m"

install_dependencies() {
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y iptables iproute2 dnsutils curl wget lsof psmisc
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iptables iproute bind-utils curl wget lsof psmisc
    else
        echo -e "${red}Unsupported system${black}"
        exit 1
    fi
}

enable_nat() {
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    iptables --policy FORWARD ACCEPT
    ip6tables --policy FORWARD ACCEPT
}

dnat_add() {
    read -rp "本地端口号: " localport
    read -rp "目标域名/IP: " remotehost
    read -rp "目标端口号: " remoteport

    # 检查端口数字
    if ! [[ $localport =~ ^[0-9]+$ ]] || ! [[ $remoteport =~ ^[0-9]+$ ]]; then
        echo -e "${red}端口必须为数字${black}"
        return
    fi

    # 解析域名
    if [[ $remotehost =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        remoteip=$remotehost
    else
        remoteip=$(host -t a $remotehost | awk '/has address/ {print $4; exit}')
        if [[ -z $remoteip ]]; then
            echo -e "${red}域名解析失败${black}"
            return
        fi
    fi

    local localIP=$(ip -o -4 addr list | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.')
    
    iptables -t nat -A PREROUTING -p tcp --dport $localport -j DNAT --to-destination $remoteip:$remoteport
    iptables -t nat -A PREROUTING -p udp --dport $localport -j DNAT --to-destination $remoteip:$remoteport
    iptables -t nat -A POSTROUTING -p tcp -d $remoteip --dport $remoteport -j SNAT --to-source $localIP
    iptables -t nat -A POSTROUTING -p udp -d $remoteip --dport $remoteport -j SNAT --to-source $localIP

    echo "$localport>$remotehost:$remoteport" >> $CONF
    echo -e "${green}添加成功${black}"
}

dnat_remove() {
    read -rp "本地端口号: " localport
    sed -i "/^$localport>.*/d" $CONF
    # 重新加载规则
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    while read -r line; do
        IFS='>: ' read -r lp host rp <<< "$line"
