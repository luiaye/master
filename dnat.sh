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

    local localIP
    localIP=$(ip -o -4 addr list | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.') 

    iptables -t nat -A PREROUTING -p tcp --dport $localport -j DNAT --to-destination $remoteip:$remoteport
    iptables -t nat -A PREROUTING -p udp --dport $localport -j DNAT --to-destination $remoteip:$remoteport
    iptables -t nat -A POSTROUTING -p tcp -d $remoteip --dport $remoteport -j SNAT --to-source $localIP
    iptables -t nat -A POSTROUTING -p udp -d $remoteip --dport $remoteport -j SNAT --to-source $localIP

    # 保存规则到配置文件
    if ! grep -q "^$localport>$remotehost:$remoteport" $CONF; then
        echo "$localport>$remotehost:$remoteport" >> $CONF
    fi

    echo -e "${green}添加成功: $localport -> $remotehost:$remoteport${black}" | tee -a $LOGFILE
}

# =============================
# 删除 DNAT 规则
# =============================
dnat_remove() {
    read -rp "本地端口号: " localport
    sed -i "/^$localport>.*/d" $CONF
    # 清空 NAT 表并重新加载配置
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    while read -r line; do
        IFS='>: ' read -r lp host rp <<< "$line"
        if [[ -n "$lp" && -n "$host" && -n "$rp" ]]; then
            local localIP
            localIP=$(ip -o -4 addr list | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.') 
            iptables -t nat -A PREROUTING -p tcp --dport $lp -j DNAT --to-destination $host:$rp
            iptables -t nat -A PREROUTING -p udp --dport $lp -j DNAT --to-destination $host:$rp
            iptables -t nat -A POSTROUTING -p tcp -d $host --dport $rp -j SNAT --to-source $localIP
            iptables -t nat -A POSTROUTING -p udp -d $host --dport $rp -j SNAT --to-source $localIP
        fi
    done < $CONF
    echo -e "${green}删除完成${black}" | tee -a $LOGFILE
}

# =============================
# 列出所有规则
# =============================
dnat_list() {
    echo -e "${yellow}当前 DNAT 配置:${black}"
    cat $CONF
}

# =============================
# 查看 iptables NAT 表
# =============================
dnat_show() {
    echo "PREROUTING:"
    iptables -t nat -L PREROUTING -n --line-number
    echo "POSTROUTING:"
    iptables -t nat -L POSTROUTING -n --line-number
}

# =============================
# 初始化
# =============================
install_dependencies
enable_nat

# =============================
# 图形化菜单循环
# =============================
while true; do
    clear
    echo "====================================="
    echo "   动态 DNAT 管理菜单"
    echo "====================================="
    echo "1) 增加转发规则"
    echo "2) 删除转发规则"
    echo "3) 列出所有规则"
    echo "4) 查看 iptables 配置"
    echo "5) 退出"
    echo "====================================="
    read -rp "请选择操作 [1-5]: " choice
    case $choice in
        1) dnat_add ;;
        2) dnat_remove ;;
        3) dnat_list ;;
        4) dnat_show ;;
        5) exit 0 ;;
        *) echo -e "${red}无效选择${black}" ;;
    esac
    read -rp "按回车继续..."
done
