#!/bin/bash
# autoXRAY-udp.sh — установщик AmneziaWG + Hysteria2 (UDP против мобильного DPI)
# Использование: bash autoXRAY-udp.sh поддомен.домен.com
set -o pipefail

GRN='\033[1;32m'; RED='\033[1;31m'; YEL='\033[1;33m'; NC='\033[0m'

# --- Task 1: root + домен ---
[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ скрипту нужны root права${NC}"; exit 1; }

DOMAIN=$1
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ Ошибка: домен не задан.${NC}"
    echo -e "${YEL}Пример: bash autoXRAY-udp.sh udp.example.com${NC}"
    exit 1
fi

# --- Task 2: системная подготовка (пакеты, BBR, лимиты) ---
echo -e "${YEL}Установка пакетов...${NC}"

# Подавляем интерактив iptables-persistent перед установкой
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections

apt-get update
apt-get install -y curl jq dnsutils openssl nginx certbot qrencode iptables iptables-persistent build-essential git
systemctl enable --now nginx

# BBR
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "net.core.default_qdisc=fq" > /etc/sysctl.d/999-autoXRAY.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/999-autoXRAY.conf
    sysctl --system
fi

# Лимиты
cat <<EOF > /etc/security/limits.d/99-autoXRAY.conf
*               soft    nofile          65535
*               hard    nofile          65535
root            soft    nofile          65535
root            hard    nofile          65535
EOF
ulimit -n 65535

# --- Task 1 (продолжение): проверка DNS (после установки dnsutils/dig) ---
LOCAL_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" | grep '^[0-9]' | head -n1)
if [ "$LOCAL_IP" != "$DNS_IP" ]; then
    echo -e "${RED}❌ IP ($LOCAL_IP) не совпадает с A-записью $DOMAIN ($DNS_IP).${NC}"
    read -rp "Продолжить на ваш страх и риск? (y/N):" choice
    [[ "$choice" =~ ^[Yy]$ ]] || { echo -e "${RED}Прервано.${NC}"; exit 1; }
fi

# --- Task 3: certbot + nginx selfsteal + хостинг подписки ---
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH" /var/www/html

# selfsteal-страница
bash -c "$(curl -L https://github.com/xVRVx/autoXRAY/raw/refs/heads/main/test/gen_page2.sh)" -- "$WEB_PATH"

# Определяем дефолтный конфиг nginx
if [ -f /etc/nginx/sites-available/default ]; then
    CONFIG_PATH="/etc/nginx/sites-available/default"
elif [ -f /etc/nginx/conf.d/default.conf ]; then
    CONFIG_PATH="/etc/nginx/conf.d/default.conf"
else
    echo -e "${RED}Не найден default-конфиг nginx${NC}"; exit 1
fi

cat > "$CONFIG_PATH" <<'NGINXEOF'
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }
    location / { return 301 https://$host$request_uri; }
}
NGINXEOF
systemctl reload nginx

# СНАЧАЛА выпускаем серт, и только при успехе работаем с файлами (в autoXRAY1.sh порядок обратный — баг)
certbot certonly --webroot -w /var/www/html -d "$DOMAIN" -m "mail@$DOMAIN" \
    --agree-tos --non-interactive --deploy-hook "systemctl reload nginx; systemctl restart hysteria-server 2>/dev/null || true"
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ CERTBOT ЗАВЕРШИЛСЯ С ОШИБКОЙ — серт не получен${NC}"; exit 1
fi
echo -e "${GRN}✅ Сертификат получен${NC}"

# Генерируем путь страницы подписки (нужен до боевого nginx-конфига)
path_subpage=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

# Боевой nginx-конфиг (TCP 443, selfsteal + хостинг подписки)
cat > "$CONFIG_PATH" <<NGINXEOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root /var/www/$DOMAIN;
    index index.html;
    ssl_certificate     "/etc/letsencrypt/live/$DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$DOMAIN/privkey.pem";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    location ~ /\\.ht { deny all; }
}
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINXEOF
systemctl restart nginx

# --- Task 4: генерация секретов и обфускации ---

# Порты
AWG_PORT=51820
HY_PORT=443
HOP_START=20000
HOP_END=40000

# Hysteria2 секреты
HY_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
HY_OBFS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)

# AmneziaWG обфускация
AWG_JC=$(( (RANDOM % 8) + 3 ))                  # 3..10
AWG_JMIN=$(( (RANDOM % 200) + 64 ))             # 64..263
AWG_JMAX=$(( AWG_JMIN + 300 + (RANDOM % 400) )) # > Jmin, в пределах 1024
[ "$AWG_JMAX" -gt 1024 ] && AWG_JMAX=1024
AWG_S1=$(( (RANDOM % 50) + 5 ))                 # 5..54
AWG_S2=$(( (RANDOM % 50) + 5 ))
while [ "$AWG_S2" -eq "$AWG_S1" ]; do AWG_S2=$(( (RANDOM % 50) + 5 )); done
rand32() { echo $(( (RANDOM << 16 | RANDOM) % 2000000000 + 100000 )); }
AWG_H1=$(rand32); AWG_H2=$(rand32); AWG_H3=$(rand32); AWG_H4=$(rand32)
# гарантируем различие H1..H4
while [ "$AWG_H2" = "$AWG_H1" ]; do AWG_H2=$(rand32); done
while [ "$AWG_H3" = "$AWG_H1" ] || [ "$AWG_H3" = "$AWG_H2" ]; do AWG_H3=$(rand32); done
while [ "$AWG_H4" = "$AWG_H1" ] || [ "$AWG_H4" = "$AWG_H2" ] || [ "$AWG_H4" = "$AWG_H3" ]; do AWG_H4=$(rand32); done

# --- Task 5: NAT и форвардинг ---
WAN_IF=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/998-autoXRAY-fwd.conf
sysctl --system

iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# --- Task 6: установка AmneziaWG (tools из исходников + модуль, фолбэк на userspace) ---
echo -e "${YEL}Установка AmneziaWG...${NC}"
apt-get install -y "linux-headers-$(uname -r)" dkms || true

# amneziawg-tools (awg, awg-quick) из исходников
if ! command -v awg >/dev/null 2>&1; then
    git clone https://github.com/amnezia-vpn/amneziawg-tools /opt/amneziawg-tools
    make -C /opt/amneziawg-tools/src -j"$(nproc)"
    make -C /opt/amneziawg-tools/src install
fi

# Модуль ядра через DKMS
AWG_MODULE_OK=0
if [ -d "/usr/src/linux-headers-$(uname -r)" ] || [ -d "/lib/modules/$(uname -r)/build" ]; then
    git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module /opt/amneziawg-module || true
    if [ -d /opt/amneziawg-module/src ]; then
        make -C /opt/amneziawg-module/src -j"$(nproc)" && \
            make -C /opt/amneziawg-module/src install && \
            depmod -a
        modprobe amneziawg 2>/dev/null && AWG_MODULE_OK=1
    fi
fi

# Фолбэк: userspace amneziawg-go
if [ "$AWG_MODULE_OK" -ne 1 ]; then
    echo -e "${YEL}Модуль ядра недоступен — ставим userspace amneziawg-go${NC}"
    if ! command -v go >/dev/null 2>&1; then
        apt-get install -y golang-go || { echo -e "${RED}Не удалось поставить Go${NC}"; }
    fi
    git clone https://github.com/amnezia-vpn/amneziawg-go /opt/amneziawg-go
    ( cd /opt/amneziawg-go && go build -o /usr/bin/amneziawg-go . )
    export WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
fi

# Ключи сервера/клиента + awg0.conf
mkdir -p /etc/amnezia/amneziawg
umask 077
AWG_SRV_PRIV=$(awg genkey)
AWG_SRV_PUB=$(echo "$AWG_SRV_PRIV" | awg pubkey)
AWG_CLI_PRIV=$(awg genkey)
AWG_CLI_PUB=$(echo "$AWG_CLI_PRIV" | awg pubkey)

cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
PrivateKey = $AWG_SRV_PRIV
Address = 10.13.13.1/24
ListenPort = $AWG_PORT
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
PostUp = iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE

[Peer]
PublicKey = $AWG_CLI_PUB
AllowedIPs = 10.13.13.2/32
EOF

systemctl enable --now awg-quick@awg0 || awg-quick up awg0

# --- Task 7: установка Hysteria2 (запиннена) + конфиг + systemd + port-hopping ---
HY_VERSION="v2.6.0"   # ПИН: обновлять вручную; не latest
echo -e "${YEL}Установка Hysteria2 $HY_VERSION...${NC}"
bash <(curl -fsSL https://get.hy2.sh/) --version "$HY_VERSION"

# Конфиг сервера Hysteria2
cat > /etc/hysteria/config.yaml <<EOF
listen: :$HY_PORT

tls:
  cert: /etc/letsencrypt/live/$DOMAIN/fullchain.pem
  key: /etc/letsencrypt/live/$DOMAIN/privkey.pem

auth:
  type: password
  password: $HY_PASS

obfs:
  type: salamander
  salamander:
    password: $HY_OBFS

masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN/
    rewriteHost: true
EOF

systemctl enable --now hysteria-server

# Port-hopping (iptables REDIRECT диапазона UDP → listen)
iptables -t nat -C PREROUTING -i "$WAN_IF" -p udp --dport "${HOP_START}:${HOP_END}" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$WAN_IF" -p udp --dport "${HOP_START}:${HOP_END}" -j REDIRECT --to-ports "$HY_PORT"
netfilter-persistent save

# --- Task 8: клиентские артефакты — AmneziaWG .conf, hysteria2:// ссылка ---
SERVER_PUB_IP="$LOCAL_IP"

# Клиентский конфиг AmneziaWG (.conf) — параметры обфускации идентичны серверу
AWG_CLIENT_CONF="[Interface]
PrivateKey = $AWG_CLI_PRIV
Address = 10.13.13.2/32
DNS = 1.1.1.1
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $AWG_SRV_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $DOMAIN:$AWG_PORT
PersistentKeepalive = 25"

echo "$AWG_CLIENT_CONF" > "$WEB_PATH/awg-client.conf"

# Hysteria2 ссылка (стандартный формат; диапазон портов через mport)
HY_LINK="hysteria2://${HY_PASS}@${DOMAIN}:${HOP_START}-${HOP_END}/?obfs=salamander&obfs-password=${HY_OBFS}&sni=${DOMAIN}#autoXRAY-UDP-Hysteria2"

# --- Task 9: HTML-страница подписки ---

# HEAD (статический, скопирован из autoXRAY1.sh, title заменён на autoXRAY UDP configs)
cat > "$WEB_PATH/$path_subpage.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>autoXRAY UDP configs</title>
<link rel="icon" type="image/svg+xml" href='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBCRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTIxIDJsLTIgMm0tNy42MSA3LjYxYTUuNSA1LjUgMCAxIDEtNy43NzggNy43NzggNS41IDUuNSAwIDAgMSA3Ljc3Ny03Ljc3N3ptMCAwTDE1LjUgNy41bTAgMGwzIDNMMjIgN2wtMy0zbS0zLjUgMy41TDE5IDQiLz48L3N2Zz4='>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
body{font-family:monospace;background:#121212;color:#e0e0e0;padding:10px;max-width:900px;margin:0 auto}h2{color:#c3e88d;border-top:2px solid #333;padding-top:20px;margin:15px 0 10px;font-size:18px}.config-row{background:#1e1e1e;border:1px solid #333;border-radius:6px;padding:5px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px}.config-label{background:#2c2c2c;color:#82aaff;padding:6px 10px;border-radius:4px;font-weight:700;font-size:13px;white-space:nowrap;min-width:140px;text-align:center}.config-code{flex:1;white-space:nowrap;overflow-x:auto;padding:8px;background:#121212;border-radius:4px;color:#c3e88d;font-size:12px;scrollbar-width:none}.config-code::-webkit-scrollbar{display:none}.btn-action{border:1px solid #555;padding:6px 12px;border-radius:4px;cursor:pointer;font-weight:700;font-size:12px;transition:all .2s;height:32px;display:flex;align-items:center;justify-content:center}.copy-btn{background:#333;color:#e0e0e0;min-width:60px}.copy-btn:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}.qr-btn{background:#333;color:#82aaff;border-color:#82aaff;min-width:40px}.qr-btn:hover{background:#82aaff;color:#121212}.btn-group{display:flex;gap:10px;margin:10px 0 20px}.btn{flex:1;background:#2c2c2c;color:#c3e88d;border:1px solid #c3e88d;padding:10px;text-align:center;border-radius:6px;text-decoration:none;font-weight:700;font-size:14px}.btn:hover{background:#c3e88d;color:#121212}.btn.download{border-color:#82aaff;color:#82aaff}.btn.download:hover{background:#82aaff;color:#121212}.btn.tg{border-color:#2AABEE;color:#2AABEE}.btn.tg:hover{background:#2AABEE;color:#fff}.modal-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.85);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(3px)}.modal-content{background:#1e1e1e;padding:20px;border-radius:10px;border:1px solid #82aaff;text-align:center}#qrcode{background:#fff;padding:10px;border-radius:6px;margin-bottom:10px}.close-modal-btn{background:#c31e1e;color:#fff;border:none;padding:8px 20px;border-radius:4px;cursor:pointer}@media(max-width:600px){.config-label{width:100%;margin-bottom:2px}.config-code{min-width:100%;order:3}.btn-action{flex:1;order:2}}
</style>
<script>
function copyText(e,t){navigator.clipboard.writeText(document.getElementById(e).innerText).then(()=>{let o=t.innerText;t.innerText="OK",t.style.cssText="background:#c3e88d;color:#121212",setTimeout(()=>{t.innerText=o,t.style.cssText=""},1500)}).catch(e=>console.error(e))}function showQR(e){let t=document.getElementById(e).innerText,o=document.getElementById("qrModal"),n=document.getElementById("qrcode");n.innerHTML="",new QRCode(n,{text:t,width:256,height:256,colorDark:"#000000",colorLight:"#ffffff",correctLevel:QRCode.CorrectLevel.L}),o.style.display="flex"}function closeModal(){document.getElementById("qrModal").style.display="none"}window.onclick=function(e){e.target==document.getElementById("qrModal")&&closeModal()};
</script>
</head><body>
EOF

# BODY (динамические данные)
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<h2>🛡️ Hysteria2 (QUIC/UDP, port-hopping ${HOP_START}-${HOP_END})</h2>
<div class="config-row">
    <div class="config-label">Hysteria2</div>
    <div class="config-code" id="hy">$HY_LINK</div>
    <button class="btn-action copy-btn" onclick="copyText('hy', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('hy')">QR</button>
</div>
<div class="btn-group">
    <a href="happ://add/$HY_LINK" class="btn">⚡ Hysteria2 → HAPP</a>
    <a href="https://www.happ.su/main/ru" target="_blank" class="btn download">⬇️ Download App</a>
</div>

<h2>🛡️ AmneziaWG (обфусцированный WireGuard, UDP $AWG_PORT)</h2>
<p>Скачайте конфиг или отсканируйте QR в приложении (Happ/AmneziaVPN): Импорт → из файла/QR.</p>
<div class="config-row">
    <div class="config-label">AmneziaWG</div>
    <div class="config-code" id="awg" style="white-space:pre-wrap;word-break:break-all;max-height:200px">$AWG_CLIENT_CONF</div>
    <button class="btn-action copy-btn" onclick="copyText('awg', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('awg')">QR</button>
</div>
<div class="btn-group">
    <a href="/awg-client.conf" download class="btn download">⬇️ Скачать awg-client.conf</a>
</div>

<div><a style="color:white;margin:40px auto 20px;display:block;text-align:center;" href="https://github.com/xVRVx/autoXRAY">https://github.com/xVRVx/autoXRAY</a></div>
<div id="qrModal" class="modal-overlay"><div class="modal-content"><div id="qrcode"></div><button class="close-modal-btn" onclick="closeModal()">Close</button></div></div>
</body></html>
EOF

# --- Task 10: финальные проверки статусов и итоговый вывод ---
echo -e "\n${YEL}=== Финальная проверка статусов ===${NC}"
for svc in nginx hysteria-server awg-quick@awg0; do
    if systemctl is-active --quiet "$svc"; then
        echo -e "$svc: ${GRN}RUNNING${NC}"
    else
        echo -e "$svc: ${RED}STOPPED/ERROR${NC}"
    fi
done

cat <<EOF

${GRN}Готово.${NC}
Страница подписки: https://$DOMAIN/$path_subpage.html

Hysteria2:  $HY_LINK
AmneziaWG:  https://$DOMAIN/awg-client.conf  (или QR на странице)

${YEL}ВАЖНО про UDP:${NC} если у оператора режется UDP — Hysteria2 пробует диапазон
$HOP_START-$HOP_END (port-hopping). Если всё равно не идёт, расширьте диапазон в
/etc/hysteria/config.yaml + правиле iptables и перезапустите hysteria-server.

Проверка UDP-портов снаружи (с другого хоста):
  nc -uvz $DOMAIN $AWG_PORT
EOF
