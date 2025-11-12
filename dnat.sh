#!/bin/bash
# ===============================================
# 动态 DNAT 管理脚本（图形化菜单版） - 修正版（MASQUERADE + 出网口自动选择）
# Author: ARLOOR (优化版 by ChatGPT)
# 新增功能：删除所有转发规则及服务
# 退出选项改为 0
# 主要修复：避免 localIP 为多行导致 "Bad argument `172.17.0.1`"
# ===============================================

set -euo pipefail

# 颜色定义
red="\033[31m"
green="\033[32m"
yellow="\033[33m"
black="\033[0m"

# 基础目录
BASE=/etc/dnat
CONF="$BASE/conf"
mkdir -p "$BASE"
touch "$CONF"

LOGFILE="$BASE/dnat.log"
echo "$(date '+%F %T') - DNAT管理脚本启动" >> "$LOGFILE"

# =============================
# 工具函数
# =============================

# 返回给定目的IP/域名的出网接口名（例如 eth0）
get_out_iface() {
    local dst="$1"
    # 先把域名解析为IP（若已是IP则保持）
    local ip
    if [[ "$dst" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="$dst"
    else
        ip=$(host -t a "$dst" | awk '/has address/ {print $4; exit}')
    fi
    [[ -z "${ip:-}" ]] && return 1
    ip route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# 将域名解析为单个IPv4（若已是IP则直接返回）
resolve_ip() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"
    else
        host -t a "$host" | awk '/has address/ {print $4; exit}'
    fi
}

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
    echo -e "${green}开启端口转发与 NAT${black}" | tee -a "$LOGFILE"
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    iptables --policy FORWARD ACCEPT
    ip6tables --policy FORWARD ACCEPT
}

# =============================
# 添加 DNAT 规则（使用 MASQUERADE，自动选择出网口）
# =============================
dnat_add() {
    read -rp "本地端口号: " localport
    read -rp "目标域名/IP: " remotehost
    read -rp "目标端口号: " remoteport

    if ! [[ "$localport" =~ ^[0-9]+$ ]] || ! [[ "$remoteport" =~ ^[0-9]+$ ]]; then
        echo -e "${red}端口必须为数字${black}"
        return
    fi

    local remoteip
    remoteip="$(resolve_ip "$remotehost")"
    if [[ -z "${remoteip:-}" ]]; then
        echo -e "${red}域名解析失败${black}"
        return
    fi

    local out_if
    out_if="$(get_out_iface "$remoteip" || true)"
    if [[ -z "${out_if:-}" ]]; then
        echo -e "${red}无法确定出网接口${black}"
        return
    fi

    # DNAT（TCP/UDP）
    iptables -t nat -A PREROUTING -p tcp --dport "$localport" -j DNAT --to-destination "$remoteip:$remoteport" \
        -m comment --comment "dnat:${localport}->${remotehost}:${remoteport}"
    iptables -t nat -A PREROUTING -p udp --dport "$localport" -j DNAT --to-destination "$remoteip:$remoteport" \
        -m comment --comment "dnat:${localport}->${remotehost}:${remoteport}"

    # POSTROUTING 使用 MASQUERADE，不再手写 --to-source，避免多IP问题
    iptables -t nat -A POSTROUTING -p tcp -d "$remoteip" --dport "$remoteport" -o "$out_if" -j MASQUERADE \
        -m comment --comment "snat:${localport}->${remotehost}:${remoteport}"
    iptables -t nat -A POSTROUTING -p udp -d "$remoteip" --dport "$remoteport" -o "$out_if" -j MASQUERADE \
        -m comment --comment "snat:${localport}->${remotehost}:${remoteport}"

    if ! grep -q "^$localport>$remotehost:$remoteport" "$CONF"; then
        echo "$localport>$remotehost:$remoteport" >> "$CONF"
    fi

    echo -e "${green}添加成功: $localport -> $remotehost:$remoteport（出网口：$out_if）${black}" | tee -a "$LOGFILE"
}

# =============================
# 删除单个 DNAT 规则
# =============================
dnat_remove() {
    read -rp "本地端口号: " localport
    sed -i "/^$localport>.*/d" "$CONF"
    reload_dnat
    echo -e "${green}删除完成${black}" | tee -a "$LOGFILE"
}

# =============================
# 重载 DNAT 配置（使用 MASQUERADE，自动选择出网口）
# =============================
reload_dnat() {
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    while read -r line; do
        [[ -z "$line" ]] && continue
        IFS='>: ' read -r lp host rp <<< "$line"
        if [[ -n "${lp:-}" && -n "${host:-}" && -n "${rp:-}" ]]; then
            local host_ip
            host_ip="$(resolve_ip "$host")"
            [[ -z "${host_ip:-}" ]] && continue

            local out_if
            out_if="$(get_out_iface "$host_ip" || true)"
            [[ -z "${out_if:-}" ]] && continue

            # DNAT
            iptables -t nat -A PREROUTING -p tcp --dport "$lp" -j DNAT --to-destination "$host_ip:$rp" \
                -m comment --comment "dnat:${lp}->${host}:${rp}"
            iptables -t nat -A PREROUTING -p udp --dport "$lp" -j DNAT --to-destination "$host_ip:$rp" \
                -m comment --comment "dnat:${lp}->${host}:${rp}"

            # MASQUERADE
            iptables -t nat -A POSTROUTING -p tcp -d "$host_ip" --dport "$rp" -o "$out_if" -j MASQUERADE \
                -m comment --comment "snat:${lp}->${host}:${rp}"
            iptables -t nat -A POSTROUTING -p udp -d "$host_ip" --dport "$rp" -o "$out_if" -j MASQUERADE \
                -m comment --comment "snat:${lp}->${host}:${rp}"
        fi
    done < "$CONF"
}

# =============================
# 删除所有 DNAT 规则和服务
# =============================
dnat_remove_all() {
    echo -e "${red}警告：将删除所有转发规则和服务！${black}"
    read -rp "确认删除？(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "已取消"
        return
    fi

    # 删除规则
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    rm -f "$CONF"
    mkdir -p "$BASE"
    touch "$CONF"
    echo -e "${green}已删除所有转发规则${black}" | tee -a "$LOGFILE"

    # 删除 systemd 服务
    if systemctl list-unit-files | grep -q dnat.service; then
        systemctl stop dnat || true
        systemctl disable dnat || true
        rm -f /lib/systemd/system/dnat.service
        systemctl daemon-reload
        echo -e "${green}已删除 DNAT 服务${black}" | tee -a "$LOGFILE"
    fi
}

# =============================
# 列出所有规则
# =============================
dnat_list() {
    echo -e "${yellow}当前 DNAT 配置:${black}"
    cat "$CONF"
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
    echo "5) 删除所有转发规则及服务"
    echo "0) 退出"
    echo "====================================="
    read -rp "请选择操作 [0-5]: " choice
    case "$choice" in
        1) dnat_add ;;
        2) dnat_remove ;;
        3) dnat_list ;;
        4) dnat_show ;;
        5) dnat_remove_all ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选择${black}" ;;
    esac
    read -rp "按回车继续..."
done
