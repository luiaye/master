#!/bin/bash
# ===============================================
# 动态 DNAT 管理脚本（支持 Debian/Ubuntu/CentOS）
# Author: ARLOOR (优化版)
# 自动安装依赖，支持 IPV4/IPV6，日志记录
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
        apt install -y iptables iproute2 curl wget dnsutils lsof psmisc
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
    local localport=$1
    local remotehost=$2
    local remoteport=$3

    # 判断端口数字合法
    if ! [[ $localport =~ ^[0-9]+$ ]] || ! [[ $remoteport =~ ^[0-9]+$ ]]; then
        echo -e "${red}端口必须为数字！${black}"
        return 1
    fi

    # 解析域名
    local remoteip
    if [[ $remotehost =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        remoteip=$remotehost
    else
        remoteip=$(host -t a $remotehost | awk '/has address/ {print $4; exit}')
        if [[ -z $remoteip ]]; then
            echo -e "${red}域名解析失败！${black}"
            return 1
        fi
    fi

    local localIP
    localIP=$(ip -o -4 addr list | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.') 

    # 添加 iptables NAT 规则
    iptables -t nat -A PREROUTING -p tcp --dport $localport -j DNAT --to-destination $remoteip:$remoteport
    iptables -t nat -A PREROUTING -p udp --dport $localport -j DNAT --to-destination $remoteip:$remoteport
    iptables -t nat -A POSTROUTING -p tcp -d $remoteip --dport $remoteport -j SNAT --to-source $localIP
    iptables -t nat -A POSTROUTING -p udp -d $remoteip --dport $remoteport -j SNAT --to-source $localIP

    echo "$localport>$remotehost:$remoteport" >> $CONF
    echo -e "${green}添加成功: $localport -> $remotehost:$remoteport${black}" | tee -a $LOGFILE
}

# =============================
# 删除 DNAT 规则
# =============================
dnat_remove() {
    local localport=$1
    sed -i "/^$localport>.*/d" $CONF
    echo -e "${green}删除规则: $localport${black}" | tee -a $LOGFILE
    # 清空 NAT 表并重载配置
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    while read -r line; do
        IFS='>: ' read -r lp host rp <<< "$line"
        dnat_add $lp $host $rp
    done < $CONF
}

# =============================
# 列出规则
# =============================
dnat_list() {
    echo -e "${yellow}当前 DNAT 配置:${black}"
    cat $CONF
}

# =============================
# 查看 iptables
# =============================
dnat_show() {
    echo "iptables PREROUTING:"
    iptables -t nat -L PREROUTING -n --line-number
    echo "iptables POSTROUTING:"
    iptables -t nat -L POSTROUTING -n --line-number
}

# =============================
# 系统服务化
# =============================
setup_service() {
    cat >/usr/lib/systemd/system/dnat.service <<EOF
[Unit]
Description=动态设置iptables转发规则
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash $BASE/dnat_loop.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    # 循环执行脚本文件
    cat >$BASE/dnat_loop.sh <<"EOS"
#!/bin/bash
BASE=/etc/dnat
CONF=$BASE/conf
while true; do
    # 自动更新域名 IP
    [ -f "$CONF" ] || touch "$CONF"
    while read -r line; do
        IFS='>: ' read -r lp host rp <<< "$line"
        /bin/bash $BASE/dnat.sh add $lp $host $rp
    done < "$CONF"
    sleep 60
done
EOS
    chmod +x $BASE/dnat_loop.sh
    systemctl daemon-reload
    systemctl enable dnat
    systemctl restart dnat
}

# =============================
# 脚本主入口
# =============================
install_dependencies
enable_nat
setup_service

echo -e "${green}DNAT管理脚本已初始化完成，可通过命令管理规则:${black}"
echo "添加: $0 add 本地端口 远程域名/IP 远程端口"
echo "删除: $0 remove 本地端口"
echo "列出: $0 list"
echo "查看iptables: $0 show"

# 命令行参数支持
case "${1:-}" in
    add)
        dnat_add "$2" "$3" "$4"
        ;;
    remove)
        dnat_remove "$2"
        ;;
    list)
        dnat_list
        ;;
    show)
        dnat_show
        ;;
    *)
        echo "请选择操作: add/remove/list/show"
        ;;
esac
