bash -c '
set -e

PORT=80
LISTEN="0.0.0.0"
USER="admin"
PASS="YUL3ojLD"

[ "$(id -u)" -ne 0 ] && echo "请使用 root 运行" && exit 1

if command -v apt-get >/dev/null 2>&1; then
  PM=apt
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf
elif command -v yum >/dev/null 2>&1; then
  PM=yum
else
  echo "不支持的系统"; exit 1
fi

if [ "$PM" = "apt" ]; then
  apt-get update -y
  apt-get install -y curl unzip ca-certificates
else
  $PM install -y curl unzip ca-certificates
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) XRAY_ARCH="64" ;;
  aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 版本号获取
VER=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | \
      sed -n "s/.*\\\"tag_name\\\": \\\"\\(v[^\\\"]*\\)\\\".*/\\1/p")
[ -z "$VER" ] && echo "获取 Xray 版本失败" && exit 1

# 下载
curl -fL \
  https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-${XRAY_ARCH}.zip \
  -o $TMPDIR/xray.zip

unzip -qo $TMPDIR/xray.zip -d $TMPDIR/xray

install -m 755 $TMPDIR/xray/xray /usr/local/bin/xray
mkdir -p /usr/local/share/xray
cp -f $TMPDIR/xray/geoip.dat /usr/local/share/xray/
cp -f $TMPDIR/xray/geosite.dat /usr/local/share/xray/

id xray >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin xray
mkdir -p /etc/xray /var/log/xray
chown -R xray:xray /var/log/xray

cat > /etc/xray/config.json <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "Socks-80.json",
      "port": ${PORT},
      "listen": "${LISTEN}",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          { "user": "${USER}", "pass": "${PASS}" }
        ],
        "udp": true,
        "ip": "0.0.0.0"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF

# ✅ systemd：内置 B1（允许非root监听 80）
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray SOCKS5
After=network.target

[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray

if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 80/udp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=80/tcp || true
  firewall-cmd --permanent --add-port=80/udp || true
  firewall-cmd --reload || true
fi

IP=$(curl -fsSL https://api.ipify.org || echo "<服务器IP>")
echo
echo "✅ Xray SOCKS5 已安装完成"
echo "SOCKS5: ${IP}:80"
echo "账号: admin"
echo "密码: YUL3ojLD"
'
