# autoXRAY-udp.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Один bash-скрипт `autoXRAY-udp.sh`, который на чистом Debian 12 (root) ставит AmneziaWG + Hysteria2 (UDP-протоколы против мобильного DPI) и отдаёт HTML-страницу подписки с QR/Happ-ссылками.

**Architecture:** Монолитный скрипт в стиле существующих `autoXRAY1.sh` (проект не использует модульность — следуем конвенции). nginx+certbot на TCP 443 (selfsteal + хостинг страницы подписки + общий TLS-серт). Hysteria2 на UDP 443 с port-hopping (iptables REDIRECT диапазона → 443), берёт серт из файлов certbot. AmneziaWG на UDP 51820 с обфускацией. NAT MASQUERADE для выхода клиентов в интернет.

**Tech Stack:** bash, nginx, certbot (Let's Encrypt), Hysteria2 (официальный бинарь, запиннен), AmneziaWG (amneziawg-tools из исходников + модуль ядра DKMS, фолбэк на userspace amneziawg-go), iptables/netfilter-persistent, qrencode, envsubst.

---

## Реальность тестирования (важно для исполнителя)

Это **установщик для удалённого Debian-VPS**. Полноценно выполнить его на машине разработки (Windows) нельзя. Поэтому:

- **Локальная проверка каждой задачи** = `bash -n autoXRAY-udp.sh` (синтаксис) + `shellcheck` (если установлен). Это и есть «тест» в шагах ниже.
- **Приёмочная проверка** (Task 11) = деплой на настоящий Debian 12 VPS с доменом, ручной чек-лист. Без неё работоспособность не подтверждена — claim'ы об успехе делать только после неё.

Если `bash` или `shellcheck` недоступны на машине: `bash -n` есть в git-bash на Windows; shellcheck опционален (отсутствие — не блокер, отметить в коммите).

---

## File Structure

| Файл | Ответственность | Действие |
|---|---|---|
| `autoXRAY-udp.sh` | весь установщик (монолит, как autoXRAY1.sh) | Create |
| `README.md` | добавить раздел про UDP-сервер | Modify |
| `docs/superpowers/specs/2026-06-05-amneziawg-hysteria2-udp-installer-design.md` | спека (уже есть) | — |

Скрипт собирается по секциям (Task 1–10). Каждая задача дописывает один блок в конец файла, проверяет `bash -n`, коммитит. Task 11 — приёмка.

---

## Task 1: Скелет — шапка, проверки, домен, DNS

**Files:**
- Create: `autoXRAY-udp.sh`

- [ ] **Step 1: Создать файл со скелетом**

```bash
#!/bin/bash
# autoXRAY-udp.sh — установщик AmneziaWG + Hysteria2 (UDP против мобильного DPI)
# Использование: bash autoXRAY-udp.sh поддомен.домен.com
set -o pipefail

GRN='\033[1;32m'; RED='\033[1;31m'; YEL='\033[1;33m'; NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ скрипту нужны root права${NC}"; exit 1; }

DOMAIN=$1
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ Ошибка: домен не задан.${NC}"
    echo -e "${YEL}Пример: bash autoXRAY-udp.sh udp.example.com${NC}"
    exit 1
fi

LOCAL_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" | grep '^[0-9]' | head -n1)
if [ "$LOCAL_IP" != "$DNS_IP" ]; then
    echo -e "${RED}❌ IP ($LOCAL_IP) не совпадает с A-записью $DOMAIN ($DNS_IP).${NC}"
    read -p "Продолжить на ваш страх и риск? (y/N):" choice
    [[ "$choice" =~ ^[Yy]$ ]] || { echo -e "${RED}Прервано.${NC}"; exit 1; }
fi
```

> Примечание: `dig` ещё не установлен на чистой системе — он ставится в Task 2. На первом запуске строка `DNS_IP` отработает после установки пакетов; чтобы не падать, проверку DNS в финальной сборке размещаем ПОСЛЕ установки пакетов (см. Task 2, Step 2 — порядок блоков). Здесь скелет фиксирует логику; при сборке перенести DNS-блок ниже apt.

- [ ] **Step 2: Проверить синтаксис**

Run: `bash -n autoXRAY-udp.sh`
Expected: пусто (код 0).

- [ ] **Step 3: Линт (если есть shellcheck)**

Run: `shellcheck autoXRAY-udp.sh || echo "shellcheck отсутствует — пропуск"`
Expected: предупреждения некритичны; синтаксических ошибок нет.

- [ ] **Step 4: Commit**

```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): скелет — проверки root/домен/DNS"
```

---

## Task 2: Системная подготовка (пакеты, BBR, лимиты) + перенос DNS-проверки

**Files:**
- Modify: `autoXRAY-udp.sh`

- [ ] **Step 1: Вставить блок установки ПЕРЕД DNS-проверкой**

Порядок в файле должен стать: root → домен непустой → **apt-блок** → DNS-проверка → BBR/лимиты.

```bash
echo -e "${YEL}Установка пакетов...${NC}"
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
```

> `iptables-persistent` при установке спросит про сохранение правил — подавляем интерактив: перед install выполнить
> `echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections` и аналог для v6.

- [ ] **Step 2: Проверить синтаксис**

Run: `bash -n autoXRAY-udp.sh`
Expected: код 0.

- [ ] **Step 3: Commit**

```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): системная подготовка — пакеты, BBR, лимиты"
```

---

## Task 3: Сертификат (certbot) + nginx selfsteal + страница подписки (хостинг)

**Files:**
- Modify: `autoXRAY-udp.sh`

- [ ] **Step 1: Временный nginx-конфиг для ACME, выпуск серта, ПОТОМ копирование (фикс бага autoXRAY1.sh)**

```bash
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH" /var/www/html

# selfsteal-страница (переиспользуем генератор из проекта)
bash -c "$(curl -L https://github.com/xVRVx/autoXRAY/raw/refs/heads/main/test/gen_page2.sh)" -- "$WEB_PATH"

# Определяем дефолтный конфиг nginx
if [ -f /etc/nginx/sites-available/default ]; then
    CONFIG_PATH="/etc/nginx/sites-available/default"
elif [ -f /etc/nginx/conf.d/default.conf ]; then
    CONFIG_PATH="/etc/nginx/conf.d/default.conf"
else
    echo -e "${RED}Не найден default-конфиг nginx${NC}"; exit 1
fi

cat > "$CONFIG_PATH" <<EOF
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
systemctl reload nginx

# СНАЧАЛА выпускаем серт, и только при успехе работаем с файлами (в autoXRAY1.sh порядок обратный — баг)
certbot certonly --webroot -w /var/www/html -d "$DOMAIN" -m "mail@$DOMAIN" \
    --agree-tos --non-interactive --deploy-hook "systemctl reload nginx; systemctl restart hysteria-server 2>/dev/null || true"
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ CERTBOT ЗАВЕРШИЛСЯ С ОШИБКОЙ — серт не получен${NC}"; exit 1
fi
echo -e "${GRN}✅ Сертификат получен${NC}"
```

- [ ] **Step 2: Боевой nginx-конфиг (TCP 443, selfsteal + хостинг подписки)**

```bash
path_subpage=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

cat > "$CONFIG_PATH" <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root /var/www/$DOMAIN;
    index index.html;
    ssl_certificate     "/etc/letsencrypt/live/$DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$DOMAIN/privkey.pem";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    location ~ /\.ht { deny all; }
}
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
systemctl restart nginx
```

- [ ] **Step 3: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): certbot (с фиксом порядка) + nginx selfsteal + хостинг подписки"
```

---

## Task 4: Генерация секретов и обфускации

**Files:**
- Modify: `autoXRAY-udp.sh`

Обфускация AmneziaWG (диапазоны из docs.amnezia.org): `Jc` 1–10; `Jmin`/`Jmax` 64–1024 и `Jmin<Jmax`; `S1`,`S2` 0–64 и `S1!=S2`; `H1..H4` — различные 32-битные >4, не пересекаются.

- [ ] **Step 1: Вставить блок генерации**

```bash
# --- Порты ---
AWG_PORT=51820
HY_PORT=443
HOP_START=20000
HOP_END=40000

# --- Hysteria2 секреты ---
HY_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
HY_OBFS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)

# --- AmneziaWG ключи (через awg, ставится в Task 6; используем wg как совместимый генератор ключей) ---
# awg genkey/pubkey форматно совместимы с wg; генерацию ключей делаем в Task 6 после установки tools.

# --- AmneziaWG обфускация ---
AWG_JC=$(( (RANDOM % 8) + 3 ))                 # 3..10
AWG_JMIN=$(( (RANDOM % 200) + 64 ))            # 64..263
AWG_JMAX=$(( AWG_JMIN + 300 + (RANDOM % 400) ))# > Jmin, в пределах 1024
[ "$AWG_JMAX" -gt 1024 ] && AWG_JMAX=1024
AWG_S1=$(( (RANDOM % 50) + 5 ))                # 5..54
AWG_S2=$(( (RANDOM % 50) + 5 ))
while [ "$AWG_S2" -eq "$AWG_S1" ]; do AWG_S2=$(( (RANDOM % 50) + 5 )); done
rand32() { echo $(( (RANDOM<<16 | RANDOM) % 2000000000 + 100000 )); }
AWG_H1=$(rand32); AWG_H2=$(rand32); AWG_H3=$(rand32); AWG_H4=$(rand32)
# гарантируем различие H1..H4
while [ "$AWG_H2" = "$AWG_H1" ]; do AWG_H2=$(rand32); done
while [ "$AWG_H3" = "$AWG_H1" ] || [ "$AWG_H3" = "$AWG_H2" ]; do AWG_H3=$(rand32); done
while [ "$AWG_H4" = "$AWG_H1" ] || [ "$AWG_H4" = "$AWG_H2" ] || [ "$AWG_H4" = "$AWG_H3" ]; do AWG_H4=$(rand32); done
```

- [ ] **Step 2: Самопроверка инвариантов обфускации (вставить временный echo для ручной сверки при разработке, затем удалить)**

Run (на Linux/git-bash, выкусив блок в отдельный файл при желании):
```bash
bash -n autoXRAY-udp.sh
```
Expected: код 0. Инварианты (`Jmin<Jmax`, `S1!=S2`, `H*` различны) гарантированы циклами выше.

- [ ] **Step 3: Commit**

```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): генерация секретов Hysteria2 и обфускации AmneziaWG"
```

---

## Task 5: NAT и форвардинг

**Files:**
- Modify: `autoXRAY-udp.sh`

- [ ] **Step 1: Вставить блок**

```bash
WAN_IF=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/998-autoXRAY-fwd.conf
sysctl --system

iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
```

- [ ] **Step 2: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): ip_forward + MASQUERADE"
```

---

## Task 6: Установка AmneziaWG (tools из исходников + модуль, фолбэк на userspace) + конфиг сервера

**Files:**
- Modify: `autoXRAY-udp.sh`

> ⚠️ Самый рискованный блок (отмечен в спеке). Стратегия: 1) собрать `amneziawg-tools`; 2) поставить модуль ядра через DKMS; 3) если модуль не поднимается — фолбэк на userspace `amneziawg-go`. Точные апстрим-команды могут меняться — на приёмке (Task 11) проверить и при расхождении обновить этот блок.

- [ ] **Step 1: Установка tools + модуля с фолбэком**

```bash
echo -e "${YEL}Установка AmneziaWG...${NC}"
apt-get install -y linux-headers-$(uname -r) dkms || true

# amneziawg-tools (awg, awg-quick) из исходников
if ! command -v awg >/dev/null 2>&1; then
    git clone https://github.com/amnezia-vpn/amneziawg-tools /opt/amneziawg-tools
    make -C /opt/amneziawg-tools/src -j"$(nproc)"
    make -C /opt/amneziawg-tools/src install
fi

# Модуль ядра через DKMS
AWG_MODULE_OK=0
if [ -d /usr/src/linux-headers-$(uname -r) ] || [ -d /lib/modules/$(uname -r)/build ]; then
    git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module /opt/amneziawg-module || true
    if [ -d /opt/amneziawg-module/src ]; then
        make -C /opt/amneziawg-module/src -j"$(nproc)" && make -C /opt/amneziawg-module/src install && depmod -a
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
```

- [ ] **Step 2: Ключи сервера/клиента + awg0.conf**

```bash
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
```

> Если используется userspace-фолбэк, `awg-quick up awg0` подхватит `WG_QUICK_USERSPACE_IMPLEMENTATION`. Для systemd-юнита прокинуть переменную через drop-in (добавить на приёмке при необходимости).

- [ ] **Step 3: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): установка AmneziaWG (модуль+фолбэк) и конфиг сервера"
```

---

## Task 7: Установка Hysteria2 (запиннена) + конфиг + systemd + port-hopping

**Files:**
- Modify: `autoXRAY-udp.sh`

Проверено по docs (apernet/hysteria-website): cert-файлы, `auth password`, `obfs salamander`, `masquerade proxy`, `listen :range` или iptables REDIRECT.

- [ ] **Step 1: Установка запиннённой версии**

```bash
HY_VERSION="v2.6.0"   # ПИН: обновлять вручную; не latest
echo -e "${YEL}Установка Hysteria2 $HY_VERSION...${NC}"
bash <(curl -fsSL https://get.hy2.sh/) --version "$HY_VERSION"
```

> Официальный установщик создаёт systemd-юнит `hysteria-server.service` и каталог `/etc/hysteria`. Если установщик недоступен — фолбэк: скачать бинарь релиза `$HY_VERSION` с GitHub в `/usr/local/bin/hysteria` и положить юнит вручную (добавить на приёмке при необходимости).

- [ ] **Step 2: Конфиг сервера**

```bash
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
```

- [ ] **Step 3: Port-hopping (iptables REDIRECT диапазона UDP → listen)**

```bash
iptables -t nat -C PREROUTING -i "$WAN_IF" -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $HY_PORT 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$WAN_IF" -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $HY_PORT
netfilter-persistent save
```

- [ ] **Step 4: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): Hysteria2 (pinned) + конфиг + port-hopping"
```

---

## Task 8: Клиентские артефакты — AmneziaWG .conf, hysteria2:// ссылка

**Files:**
- Modify: `autoXRAY-udp.sh`

- [ ] **Step 1: Сформировать клиентский awg .conf и hysteria2-ссылку**

```bash
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
```

- [ ] **Step 2: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): клиентский awg .conf и hysteria2 ссылка"
```

---

## Task 9: HTML-страница подписки (переиспользование генератора autoXRAY)

**Files:**
- Modify: `autoXRAY-udp.sh`

Переиспользуем структуру HTML из `autoXRAY1.sh` (строки ~948–1026): тот же `<head>` со стилями/JS (qrcodejs, copyText, showQR, модалка). Отличия — содержимое блоков: Hysteria2-ссылка и AmneziaWG-конфиг.

- [ ] **Step 1: Записать HEAD (статический, скопировать из autoXRAY1.sh без изменений)**

```bash
cat > "$WEB_PATH/$path_subpage.html" <<'EOF'
<!-- ВСТАВИТЬ дословно <head>...</head> и открытие <body> из autoXRAY1.sh (строки 948–961):
     те же <style> и <script> (qrcodejs, copyText/showQR/closeModal), title заменить на "autoXRAY UDP configs" -->
EOF
```

> При реализации: скопировать конкретный HEAD-блок из `autoXRAY1.sh`, заменив `<title>` на `autoXRAY UDP configs`. Не сокращать стили/скрипты — они нужны для Copy/QR.

- [ ] **Step 2: Записать BODY (динамика)**

```bash
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
```

> Примечание про QR AmneziaWG: qrcodejs кодирует текст конфига как есть; Happ/AmneziaVPN умеют импортировать WG/AmneziaWG-конфиг из QR. Если конфиг длинный — QR плотный; альтернатива — кнопка скачивания `.conf` (уже добавлена).

- [ ] **Step 3: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): HTML-страница подписки (Hysteria2 + AmneziaWG)"
```

---

## Task 10: Финальные проверки статусов и итоговый вывод

**Files:**
- Modify: `autoXRAY-udp.sh`

- [ ] **Step 1: Блок проверок и вывода**

```bash
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
```

- [ ] **Step 2: Синтаксис + commit**

Run: `bash -n autoXRAY-udp.sh`
```bash
git add autoXRAY-udp.sh
git commit -m "feat(udp): финальные проверки и итоговый вывод"
```

---

## Task 11: Приёмочное тестирование на реальном Debian 12 VPS (ручное)

**Files:** —

Без этой задачи работоспособность НЕ подтверждена. Выполняет пользователь/исполнитель на настоящем VPS с доменом.

- [ ] **Step 1: Деплой**

```bash
scp autoXRAY-udp.sh root@VPS:/root/
ssh root@VPS 'bash /root/autoXRAY-udp.sh udp.ВАШДОМЕН.com'
```
Expected: блок «Финальная проверка» — все три сервиса `RUNNING`; серт получен.

- [ ] **Step 2: Проверить слушающие порты на сервере**

Run на VPS: `ss -uangp | grep -E ':(443|51820)'`
Expected: hysteria на UDP 443, amneziawg на UDP 51820.

- [ ] **Step 3: Проверить selfsteal**

Run: `curl -kI https://udp.ВАШДОМЕН.com/`
Expected: 200 и отдаётся сайт-маскировка (не дефолтная страница nginx).

- [ ] **Step 4: Клиентская проверка (Happ на мобильном интернете оператора)**

- [ ] Импортировать Hysteria2-ссылку → подключиться → открыть 2ip.ru: IP сервера, есть интернет.
- [ ] Импортировать AmneziaWG (.conf/QR) → подключиться → есть интернет.
- [ ] Подержать соединение 15–20 мин под нагрузкой (видео/скачивание) — убедиться, что нет «5 мин вкл / 5 мин выкл», в отличие от TCP-REALITY.

- [ ] **Step 5: Зафиксировать результат**

Если оба протокола стабильны на мобильном — цель достигнута. Если UDP режется — расширить hopping-диапазон (Task 10 подсказка) и/или сменить `AWG_PORT`; повторить.

---

## README (Task 12, опционально после приёмки)

**Files:** Modify `README.md`

- [ ] Добавить раздел «UDP-сервер против мобильного DPI (AmneziaWG + Hysteria2)» с командой запуска `autoXRAY-udp.sh`, требованием открытого UDP у хостера и пометкой про port-hopping. Коммит: `docs: README — раздел про autoXRAY-udp.sh`.

---

## Self-Review (выполнено при написании плана)

- **Покрытие спеки:** §1 интерфейс→T1; §2 архитектура/порты→T3,T6,T7; §3 секреты/обфускация→T4,T6; §4 установка→T2,T6,T7; §5 вывод/подписка→T8,T9; §6 ошибки/проверки→T1,T3,T10; §7 идемпотентность→вся логика перегенерации; §8 решения→порты/имена соблюдены; §9 риски→отмечены в T6/T7/T10/T11.
- **Плейсхолдеры:** код конкретен; единственное намеренное «вставить дословно» — HEAD HTML из autoXRAY1.sh (чтобы не дублировать 120 строк стилей); указаны точные строки-источника (948–961).
- **Согласованность имён:** переменные сквозные — `DOMAIN, WEB_PATH, CONFIG_PATH, path_subpage, AWG_PORT, HY_PORT, HOP_START/END, HY_PASS, HY_OBFS, AWG_*` (Jc/Jmin/Jmax/S1/S2/H1-4), `AWG_SRV_PRIV/PUB, AWG_CLI_PRIV/PUB, AWG_CLIENT_CONF, HY_LINK, WAN_IF` — определяются до использования.
- **Известное ограничение:** точные апстрим-команды AmneziaWG (T6) и установщик Hysteria2 (T7) подтверждаются/правятся на приёмке T11 — отмечено явно, это не placeholder, а условная install-логика.
