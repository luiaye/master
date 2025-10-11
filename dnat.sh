#!/bin/bash
# ===============================================
# 动态 DNAT 管理脚本（图形化菜单版）
# Author: ARLOOR (优化版)
# 自动安装依赖，支持 IPv4/IPV6，日志记录
# ===============================================

set -euo pipefail

# 颜色定义
red="\033[31m"
green="\033[32m"
yellow="\033[33m"
black="\033[0m"

# 基础目录
BASE=/etc/dnat
CONF=$BASE/conf
mkdir -p $BASE
touch $CONF

LOGFILE=$BASE/dnat.log
echo "$(date '+%F %T') - DNAT管理脚本启动" >> $LOGFILE

# =============================
# 自动安装依赖
# =============================
install_dependencies() {
    echo -e "${green}正在安装依赖...${black}"
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y iptables iproute2 dnsutils curl wget lsof psmisc
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iptables iproute bind-utils curl wget lsof psmisc
    else
        echo -e "${red}不支持的系统，请手动安装依赖！${black}"
        exit 1
    fi
    echo -e "${green}依赖安装完成${black}"
}

# =============================
# 启用 IP 转发和开放 FORWARD 链
# =============================
enable_nat() {
    echo -e "${green}开启端口转发与 NAT${black}" | tee -a $LOGFILE
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    iptables --policy FORWARD ACCEPT
    ip6tables --policy FORWARD ACCEPT
}

# =============================
# 添加 DNAT 规则
# =============================
dnat_add() {
    read -rp
