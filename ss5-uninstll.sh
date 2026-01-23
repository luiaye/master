bash -c '
set -e

echo "[1/6] 停止并禁用服务..."
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

echo "[2/6] 删除 systemd 服务文件..."
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload

echo "[3/6] 删除 Xray 程序文件..."
rm -f /usr/local/bin/xray
setcap -r /usr/local/bin/xray 2>/dev/null || true

echo "[4/6] 删除配置和日志..."
rm -rf /etc/xray
rm -rf /var/log/xray

echo "[5/6] 删除运行用户..."
id xray >/dev/null 2>&1 && userdel xray || true

echo "[6/6] 清理防火墙规则（如存在）..."
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow 80/tcp 2>/dev/null || true
  ufw delete allow 80/udp 2>/dev/null || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --remove-port=80/tcp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=80/udp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

echo
echo "✅ Xray + SOCKS5 已完全卸载"
'
