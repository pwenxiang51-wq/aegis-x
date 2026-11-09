#!/bin/bash
export LANG=en_US.UTF-8
set -uo pipefail
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; cyan='\033[0;36m'; blue='\033[0;94m'; purple='\033[1;35m'; plain='\033[0m'
ax_VERSION="1.1.4"
SCRIPT_URL="https://raw.githubusercontent.com/pwenxiang51-wq/aegis-x/main/ax.sh"
WORK_DIR="/etc/aegis-x"
BIN_XRAY="/usr/local/bin/aegis-xray"
BIN_ARGO="/usr/local/bin/aegis-argo"
SHORTCUT="/usr/local/bin/ax"
CONF_FILE="${WORK_DIR}/config.json"
META_FILE="${WORK_DIR}/node.env"
SUB_FILE="${WORK_DIR}/sub.txt"
SUB_DIR="${WORK_DIR}/sub"
CERT_FILE="${WORK_DIR}/cert.pem"
KEY_FILE="${WORK_DIR}/key.pem"
[[ $EUID -ne 0 ]] && echo -e "${red}❌ 错误: 请使用 root 用户运行！${plain}" && exit 1
trap 'rm -f /tmp/ax_* "${WORK_DIR}/config.test.json" 2>/dev/null; echo -e "\n${yellow}⚠️ 操作已取消。${plain}"; exit 130' INT TERM

clean_host() {
    local v="${1//[[:space:]]/}"
    v="${v#http://}"; v="${v#https://}"; echo "${v%%/*}"
}

env_guard() {
    mkdir -p "$WORK_DIR" "$SUB_DIR" && chmod 700 "$WORK_DIR"
    [[ -f "$0" && "$(realpath "$0" 2>/dev/null)" != "$WORK_DIR/ax.sh" ]] && cp -f "$0" "$WORK_DIR/ax.sh" 2>/dev/null || true
    [[ ! -s "$WORK_DIR/ax.sh" ]] && curl -fsSL -m 10 "$SCRIPT_URL" -o "$WORK_DIR/ax.sh" 2>/dev/null || true
    chmod +x "$WORK_DIR/ax.sh" 2>/dev/null && ln -sf "$WORK_DIR/ax.sh" "$SHORTCUT"
    local miss=()
    for c in curl jq unzip qrencode openssl; do ! command -v "$c" &>/dev/null && miss+=("$c"); done
    ! command -v ss &>/dev/null && miss+=("iproute2")
    ! command -v python3 &>/dev/null && miss+=("python3")
    if [[ ${#miss[@]} -gt 0 ]]; then
        echo -e "${cyan}>>> 正在补全依赖 (${miss[*]})...${plain}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq "${miss[@]}" ca-certificates >/dev/null 2>&1
    fi
}

get_bbr_stat() {
    local bbr="" rmem=""
    read -r bbr < /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || bbr="unknown"
    if [[ "$bbr" == *"bbr"* ]]; then
        rmem=$(sysctl -n net.core.rmem_max 2>/dev/null | tr -d '\r')
        [[ "$rmem" -ge 33554432 ]] 2>/dev/null && echo -e "${green}BBR${plain} ${purple}[32MB 极速版]${plain}" && return
        [[ "$rmem" -ge 16777216 ]] 2>/dev/null && echo -e "${green}BBR${plain} ${cyan}[16MB 标准版]${plain}" && return
        echo -e "${green}BBR${plain} ${cyan}[已开启]${plain}"
    else
        echo -e "${yellow}${bbr^^}${plain}"
    fi
}

ensure_bbr() {
    grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null && return 0
    modprobe tcp_bbr 2>/dev/null || true
    sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net.ipv4.tcp_fastopen/d' /etc/sysctl.conf 2>/dev/null || true
    printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.tcp_fastopen=3\n" >> /etc/sysctl.conf
    if ! grep -q "net.core.rmem_max" /etc/sysctl.conf 2>/dev/null; then
        printf "net.core.rmem_max=16777216\nnet.core.wmem_max=16777216\nnet.ipv4.tcp_rmem=4096 87380 16777216\nnet.ipv4.tcp_wmem=4096 65536 16777216\n" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1 || true
}

# act open|close  p: port or a-b  proto tcp|udp
manage_port() {
    local act="$1" p="${2:-}" proto="${3:-tcp}"
    [[ -z "$p" ]] && return 0
    if [[ "$p" == *-* ]]; then
        local a="${p%-*}" b="${p#*-}"
        if [[ "$act" == "open" ]]; then
            command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && ufw allow "${a}:${b}/${proto}" >/dev/null 2>&1 || true
            iptables -C INPUT -p "$proto" --dport "$a:$b" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$a:$b" -j ACCEPT 2>/dev/null || true
            ip6tables -C INPUT -p "$proto" --dport "$a:$b" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p "$proto" --dport "$a:$b" -j ACCEPT 2>/dev/null || true
        else
            command -v ufw &>/dev/null && ufw delete allow "${a}:${b}/${proto}" >/dev/null 2>&1 || true
            iptables -D INPUT -p "$proto" --dport "$a:$b" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p "$proto" --dport "$a:$b" -j ACCEPT 2>/dev/null || true
        fi
    else
        if [[ "$act" == "open" ]]; then
            command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && ufw allow "${p}/${proto}" >/dev/null 2>&1 || true
            iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
            ip6tables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
        else
            command -v ufw &>/dev/null && ufw delete allow "${p}/${proto}" >/dev/null 2>&1 || true
            iptables -D INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
        fi
    fi
}

# UDP 端口跳跃：范围 REDIRECT 到主端口
manage_hop_redirect() {
    local act="$1" main_p="$2" range="$3"
    [[ -z "$main_p" || -z "$range" || "$range" != *-* ]] && return 0
    local a="${range%-*}" b="${range#*-}"
    if [[ "$act" == "open" ]]; then
        iptables -t nat -C PREROUTING -p udp --dport "$a:$b" -j REDIRECT --to-ports "$main_p" 2>/dev/null \
            || iptables -t nat -A PREROUTING -p udp --dport "$a:$b" -j REDIRECT --to-ports "$main_p" 2>/dev/null || true
        ip6tables -t nat -C PREROUTING -p udp --dport "$a:$b" -j REDIRECT --to-ports "$main_p" 2>/dev/null \
            || ip6tables -t nat -A PREROUTING -p udp --dport "$a:$b" -j REDIRECT --to-ports "$main_p" 2>/dev/null || true
    else
        iptables -t nat -D PREROUTING -p udp --dport "$a:$b" -j REDIRECT --to-ports "$main_p" 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -p udp --dport "$a:$b" -j REDIRECT --to-ports "$main_p" 2>/dev/null || true
    fi
}

install_xray() {
    local arch="64"; [[ "$(uname -m)" =~ aarch64|arm64 ]] && arch="arm64-v8a"
    echo -e "${yellow}>>> 正在下载最新 Xray-core (linux-${arch})...${plain}"
    curl -fsSL --retry 2 -m 20 "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" -o /tmp/ax_xray.zip || { echo -e "${red}❌ 下载失败！${plain}"; return 1; }
    unzip -qo /tmp/ax_xray.zip xray -d /tmp/ && rm -f /tmp/ax_xray.zip && chmod +x /tmp/xray
    /tmp/xray version >/dev/null 2>&1 || { rm -f /tmp/xray; echo -e "${red}❌ 内核校验失败！${plain}"; return 1; }
    mv -f /tmp/xray "$BIN_XRAY"
}

# 完整 ML-KEM-768（第二套长密钥）
gen_vlessenc() {
    local raw
    raw=$("$BIN_XRAY" vlessenc 2>/dev/null) || return 1
    dec=$(printf '%s\n' "$raw" | awk -F'"' '/"decryption"/{d=$4} END{print d}')
    enc=$(printf '%s\n' "$raw" | awk -F'"' '/"encryption"/{e=$4} END{print e}')
    [[ -n "$dec" && -n "$enc" && "$dec" == mlkem768* && "$enc" == mlkem768* ]] || return 1
    printf '%s\n%s\n' "$dec" "$enc"
}

gen_self_signed() {
    local cn="${1:-aegis-x.local}"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn}" >/dev/null 2>&1 \
        || openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn}" >/dev/null 2>&1
    chmod 600 "$KEY_FILE" "$CERT_FILE" 2>/dev/null
    [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]
}

# IP → sslip.io 域名：1.2.3.4 → 1-2-3-4.sslip.io
ip_to_sslip() {
    local ip="$1"
    echo "${ip//./-}.sslip.io"
}

install_acme() {
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        return 0
    fi
    echo -e "${yellow}>>> 安装 acme.sh ...${plain}"
    # 邮箱必须带点：主机名 racknerd-c1a129d 无点，LE 会拒 ax@racknerd-c1a129d
    curl -fsSL https://get.acme.sh | sh -s email="ax@aegis-x.local" || return 1
    [[ -x "$HOME/.acme.sh/acme.sh" ]] || return 1
}

# 申请证书：domain 写入 CERT/KEY；成功返回 0
issue_acme() {
    local domain="$1"
    install_acme || { echo -e "${red}❌ acme.sh 安装失败${plain}"; return 1; }
    # 80 被占用则无法 standalone
    if ss -tlnp 2>/dev/null | grep -qE ':80\b'; then
        echo -e "${red}❌ 80 端口被占用，无法 HTTP-01 申请证书。请先停掉占用 80 的服务，或改用自签。${plain}"
        return 1
    fi
    echo -e "${yellow}>>> 正在为 ${domain} 申请 Let's Encrypt 证书（standalone）...${plain}"
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    if ! "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 --force; then
        # 再试 RSA
        "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone --force || {
            echo -e "${red}❌ 证书申请失败${plain}"
            return 1
        }
    fi
    local cer key
    for cer in \
        "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" \
        "$HOME/.acme.sh/${domain}/fullchain.cer"
    do
        [[ -s "$cer" ]] && break
    done
    for key in \
        "$HOME/.acme.sh/${domain}_ecc/${domain}.key" \
        "$HOME/.acme.sh/${domain}/${domain}.key"
    do
        [[ -s "$key" ]] && break
    done
    if [[ ! -s "$cer" || ! -s "$key" ]]; then
        echo -e "${red}❌ 找不到签发后的证书文件${plain}"
        return 1
    fi
    cp -f "$cer" "$CERT_FILE"
    cp -f "$key" "$KEY_FILE"
    chmod 600 "$CERT_FILE" "$KEY_FILE"
    # 续签后自动装回
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
        --fullchain-file "$CERT_FILE" \
        --key-file "$KEY_FILE" \
        --reloadcmd "systemctl restart aegis-xray" >/dev/null 2>&1 || true
    echo -e "${green}✅ 证书已就绪: ${domain}${plain}"
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer 2>/dev/null || true
}


start_sub_server() {
    local port="$1" token="$2"
    mkdir -p "$SUB_DIR"
    ln -sfd "$SUB_FILE" "${SUB_DIR}/${token}"
    cat > /etc/systemd/system/aegis-sub.service <<EOF
[Unit]
Description=Aegis-X Subscription HTTP
After=network.target
[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
ExecStart=$(command -v python3) -m http.server ${port} --bind 0.0.0.0
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now aegis-sub >/dev/null 2>&1
    systemctl restart aegis-sub
    manage_port open "$port" tcp
}

stop_sub_server() {
    local port="${1:-}"
    systemctl disable --now aegis-sub 2>/dev/null || true
    rm -f /etc/systemd/system/aegis-sub.service
    systemctl daemon-reload
    [[ -n "$port" ]] && manage_port close "$port" tcp
}

refresh_sub_file() {
    [[ -f "$META_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$META_FILE"
    local ip pe hop_q sni_host fa
    ip=$(curl -fsSL4 -m 3 icanhazip.com 2>/dev/null || curl -fsSL4 -m 3 ip.sb 2>/dev/null || echo "YOUR_IP")
    pe="${XHTTP_PATH//\//%2F}"
    : > "$SUB_FILE"
    if [[ "${ENABLE_TCP:-0}" == "1" && -n "${PORT:-}" ]]; then
        echo "vless://${UUID}@${ip}:${PORT}?encryption=${ENC_KEY}&flow=xtls-rprx-vision&security=none&type=xhttp&path=${pe}&mode=auto#vless-xhttp-tcp" >> "$SUB_FILE"
    fi
    if [[ "${ENABLE_UDP:-0}" == "1" && -n "${UDP_PORT:-}" ]]; then
        hop_q=""; [[ -n "${HOP_RANGE:-}" ]] && hop_q="&mport=${HOP_RANGE}"
        sni_host="${UDP_SNI:-aegis-x.local}"
        insecure_q=""; [[ "${ALLOW_INSECURE:-1}" == "1" ]] && insecure_q="&allowInsecure=1"
        echo "vless://${UUID}@${ip}:${UDP_PORT}?encryption=${ENC_KEY}&security=tls&sni=${sni_host}&fp=chrome&alpn=h3&type=xhttp&path=${pe}&mode=stream-one${insecure_q}${hop_q}#vless-xhttp-udp" >> "$SUB_FILE"
    fi
    if systemctl is-active --quiet aegis-argo-fixed && [[ -n "${ARGO_FIXED_DOMAIN:-}" ]]; then
        fa="${CF_ADDR_FIXED:-www.visa.com.hk}"
        echo "vless://${UUID}@${fa}:443?encryption=${ENC_KEY}&flow=xtls-rprx-vision&security=tls&sni=${ARGO_FIXED_DOMAIN}&host=${ARGO_FIXED_DOMAIN}&alpn=h2&fp=chrome&type=xhttp&path=${pe}&mode=packet-up#vless-xhttp-argo" >> "$SUB_FILE"
    fi
    chmod 644 "$SUB_FILE"
    if [[ -n "${SUB_TOKEN:-}" && -d "$SUB_DIR" ]]; then
        ln -sfd "$SUB_FILE" "${SUB_DIR}/${SUB_TOKEN}"
    fi
}

pick_port() {
    local hint="$1" old="${2:-}" prefer443="${3:-0}"
    local in_p port=""
    local range_hint="1-65535"
    [[ "$prefer443" == "1" ]] && range_hint="回车=443，或 1-65535"
    read -rp "👉 ${hint} [${range_hint}]: " in_p
    in_p="${in_p//[[:space:]]/}"
    if [[ -z "$in_p" && "$prefer443" == "1" ]]; then
        in_p="443"
    fi
    if [[ "$in_p" =~ ^[0-9]+$ ]] && (( in_p >= 1 && in_p <= 65535 )) && { [[ "$in_p" == "$old" ]] || ! ss -tulpn 2>/dev/null | grep -qE ":${in_p}\b"; }; then
        port="$in_p"
    else
        [[ -n "$in_p" ]] && echo -e "${yellow}⚠️ 端口无效或已占用，自动随机...${plain}" >&2
        while true; do port=$(shuf -i 20000-58000 -n 1); ! ss -tulpn 2>/dev/null | grep -qE ":${port}\b" && break; done
    fi
    printf '%s\n' "$port"
}

maybe_qr() {
    local link="$1"
    if [[ ${#link} -le 1200 ]]; then
        echo "$link" | qrencode -t UTF8 -m 1 2>/dev/null || true
    else
        echo -e "${yellow}⚠️ 链接过长，跳过终端二维码（请用订阅）${plain}"
    fi
}

deploy_xhttp() {
    local old_p="" old_udp="" f_dom="" f_addr="www.visa.com.hk"
    local old_hop="" old_sub_port="" old_sub_token=""
    # shellcheck disable=SC1090
    [[ -f "$META_FILE" ]] && source "$META_FILE" \
        && old_p="${PORT:-}" && old_udp="${UDP_PORT:-}" \
        && f_dom="${ARGO_FIXED_DOMAIN:-}" && f_addr="${CF_ADDR_FIXED:-www.visa.com.hk}" \
        && old_hop="${HOP_RANGE:-}" && old_sub_port="${SUB_PORT:-}" && old_sub_token="${SUB_TOKEN:-}"

    if systemctl is-active --quiet aegis-xray && [[ -n "${old_p}${old_udp}" ]]; then
        read -rp "⚠️ 节点已在运行，确认重置配置？[y/N]: " rc
        [[ "${rc//[[:space:]]/}" != [yY] ]] && return 0
    fi

    echo -e "\n${cyan}选择部署模式:${plain}"
    echo -e "  ${cyan}1.${plain} 仅 TCP（直连 XHTTP）"
    echo -e "  ${cyan}2.${plain} 仅 UDP（H3 + TLS + 端口跳跃）"
    echo -e "  ${cyan}3.${plain} TCP + UDP 都开"
    echo -e "  ${cyan}0.${plain} 返回主菜单"
    read -rp "👉 请选择 [0-3，回车=1]: " mode; mode="${mode:-1}"
    mode="${mode//[[:space:]]/}"
    if [[ "$mode" == "0" ]]; then
        echo -e "${yellow}已取消部署，返回主菜单。${plain}"
        return 0
    fi
    [[ "$mode" =~ ^[123]$ ]] || mode=1

    local enable_tcp=0 enable_udp=0
    case "$mode" in
        1) enable_tcp=1 ;;
        2) enable_udp=1 ;;
        3) enable_tcp=1; enable_udp=1 ;;
    esac

    ensure_bbr
    [[ ! -x "$BIN_XRAY" ]] && { install_xray || return 1; }

    local port="" udp_port="" hop_range="" uuid path keys dec enc
    local UDP_SNI_VAL="" CERT_MODE_VAL="self" ALLOW_INSECURE_VAL="1"
    uuid=$("$BIN_XRAY" uuid)
    path="/$(tr -d '-' <<<"$uuid" | cut -c1-16)"
    keys=$(gen_vlessenc) || { echo -e "${red}❌ 生成 ML-KEM-768 密钥失败！${plain}"; return 1; }
    dec=$(sed -n '1p' <<<"$keys")
    enc=$(sed -n '2p' <<<"$keys")

    if [[ "$enable_tcp" -eq 1 ]]; then
        port=$(pick_port "TCP 监听端口" "$old_p")
    fi

    if [[ "$enable_udp" -eq 1 ]]; then
        echo -e "${cyan}UDP/H3 端口建议 443（更像正常 HTTPS），也可高位。${plain}"
        udp_port=$(pick_port "UDP 监听端口" "$old_udp" 1)
        read -rp "👉 端口跳跃范围 [回车=默认约1000端口 / 如 40000-40999 / 0=关闭]: " hop_in
        hop_in="${hop_in//[[:space:]]/}"
        if [[ "$hop_in" == "0" ]]; then
            hop_range=""
        elif [[ "$hop_in" =~ ^[0-9]+-[0-9]+$ ]]; then
            local ha="${hop_in%-*}" hb="${hop_in#*-}"
            if (( hb > ha && (hb - ha) <= 5000 && ha >= 1024 && hb <= 65535 )); then
                hop_range="$hop_in"
            else
                echo -e "${yellow}⚠️ 范围无效或过宽，改用默认${plain}"
                hop_in=""
            fi
        fi
        if [[ -z "${hop_in:-}" ]]; then
            local start=$((udp_port)) end=$((udp_port + 999))
            if (( end > 65535 )); then end=65535; start=$((end - 999)); fi
            (( start < 1024 )) && start=1024
            hop_range="${start}-${end}"
        fi
        echo -e "\n${cyan}UDP TLS 证书:${plain}"
        echo -e "  ${cyan}1.${plain} sslip.io + Let's Encrypt 真证书（推荐，无需改 DNS）"
        echo -e "  ${cyan}2.${plain} 自有域名 + Let's Encrypt（需域名已解析到本机）"
        echo -e "  ${cyan}3.${plain} 自签证书（仅测试，部分客户端 H3 可能不通）"
        read -rp "👉 请选择 [1-3，回车=1]: " cm; cm="${cm:-1}"; cm="${cm//[[:space:]]/}"
        local pub_ip cert_ok=0
        pub_ip=$(curl -fsSL4 -m 3 icanhazip.com 2>/dev/null || curl -fsSL4 -m 3 ip.sb 2>/dev/null || true)
        case "$cm" in
            2)
                read -rp "👉 输入已解析到本机的域名: " udom
                udom=$(clean_host "$udom")
                if [[ -n "$udom" && "$udom" == *.* ]] && issue_acme "$udom"; then
                    UDP_SNI_VAL="$udom"
                    CERT_MODE_VAL="acme"
                    ALLOW_INSECURE_VAL="0"
                    cert_ok=1
                else
                    echo -e "${yellow}⚠️ ACME 失败，回退自签${plain}"
                fi
                ;;
            3) ;;
            *)
                if [[ -n "$pub_ip" ]]; then
                    local sslip; sslip=$(ip_to_sslip "$pub_ip")
                    echo -e "${cyan}将使用域名: ${sslip}${plain}"
                    if issue_acme "$sslip"; then
                        UDP_SNI_VAL="$sslip"
                        CERT_MODE_VAL="acme"
                        ALLOW_INSECURE_VAL="0"
                        cert_ok=1
                    else
                        echo -e "${yellow}⚠️ ACME 失败，回退自签${plain}"
                    fi
                else
                    echo -e "${yellow}⚠️ 无法获取公网 IP，回退自签${plain}"
                fi
                ;;
        esac
        if [[ "$cert_ok" -ne 1 ]]; then
            if ! gen_self_signed "aegis-x.local"; then
                echo -e "${red}❌ 自签证书失败！${plain}"; return 1
            fi
            UDP_SNI_VAL="aegis-x.local"
            CERT_MODE_VAL="self"
            ALLOW_INSECURE_VAL="1"
            echo -e "${green}✅ 自签证书 CN=aegis-x.local（链接将带 allowInsecure=1）${plain}"
        fi
    fi

    local inbounds="[" first=1
    if [[ "$enable_tcp" -eq 1 ]]; then
        first=0
        inbounds+="{\"tag\":\"vless-xhttp-tcp\",\"port\":${port},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"${dec}\"},\"streamSettings\":{\"network\":\"xhttp\",\"xhttpSettings\":{\"path\":\"${path}\",\"mode\":\"auto\"},\"security\":\"none\",\"sockopt\":{\"tcpFastOpen\":true}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"routeOnly\":true}}"
    fi
    if [[ "$enable_udp" -eq 1 ]]; then
        [[ "$first" -eq 0 ]] && inbounds+=","
        inbounds+="{\"tag\":\"vless-xhttp-udp\",\"port\":${udp_port},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${uuid}\"}],\"decryption\":\"${dec}\"},\"streamSettings\":{\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"${CERT_FILE}\",\"keyFile\":\"${KEY_FILE}\"}],\"alpn\":[\"h3\"]},\"xhttpSettings\":{\"path\":\"${path}\",\"mode\":\"stream-one\"}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"routeOnly\":true}}"
    fi
    inbounds+="]"

    cat > "${WORK_DIR}/config.test.json" <<EOF
{"log":{"loglevel":"warning"},"inbounds":${inbounds},"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOF
    if command -v jq &>/dev/null; then
        jq . "${WORK_DIR}/config.test.json" > "${WORK_DIR}/config.test.json.pretty" \
            && mv -f "${WORK_DIR}/config.test.json.pretty" "${WORK_DIR}/config.test.json"
    fi
    if ! "$BIN_XRAY" run -test -format json -c "${WORK_DIR}/config.test.json" 2>/tmp/ax_test.err; then
        echo -e "${red}❌ JSON 预检失败，已阻断写入！${plain}"
        [[ -s /tmp/ax_test.err ]] && cat /tmp/ax_test.err
        rm -f "${WORK_DIR}/config.test.json" /tmp/ax_test.err
        return 1
    fi
    mv -f "${WORK_DIR}/config.test.json" "$CONF_FILE" && chmod 600 "$CONF_FILE"
    rm -f /tmp/ax_test.err

    cat > /etc/systemd/system/aegis-xray.service <<EOF
[Unit]
Description=Aegis-X Xray Service
After=network.target
[Service]
Type=simple
ExecStart=${BIN_XRAY} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now aegis-xray >/dev/null 2>&1 && systemctl restart aegis-xray

    # 清理旧规则
    [[ -n "$old_p" && "$old_p" != "${port:-}" ]] && manage_port close "$old_p" tcp
    [[ -n "$old_udp" ]] && manage_port close "$old_udp" udp
    [[ -n "$old_hop" && -n "$old_udp" ]] && manage_hop_redirect close "$old_udp" "$old_hop" && manage_port close "$old_hop" udp

    [[ -n "${port:-}" ]] && manage_port open "$port" tcp
    if [[ -n "${udp_port:-}" ]]; then
        manage_port open "$udp_port" udp
        if [[ -n "$hop_range" ]]; then
            manage_port open "$hop_range" udp
            manage_hop_redirect open "$udp_port" "$hop_range"
            echo -e "${green}✅ 端口跳跃: ${hop_range} → UDP ${udp_port}${plain}"
        fi
    fi

    local sub_port="${old_sub_port:-}" sub_token="${old_sub_token:-}"
    [[ -z "$sub_token" ]] && sub_token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    if [[ -z "$sub_port" ]]; then
        while true; do sub_port=$(shuf -i 18000-28000 -n 1); ! ss -tulpn 2>/dev/null | grep -qE ":${sub_port}\b" && break; done
    fi
    start_sub_server "$sub_port" "$sub_token"

    cat > "$META_FILE" <<EOF
PORT="${port:-}"
UDP_PORT="${udp_port:-}"
UUID="${uuid}"
XHTTP_PATH="${path}"
ENC_KEY="${enc}"
DEC_KEY="${dec}"
ENABLE_TCP="${enable_tcp}"
ENABLE_UDP="${enable_udp}"
HOP_RANGE="${hop_range:-}"
UDP_SNI="${UDP_SNI_VAL:-aegis-x.local}"
CERT_MODE="${CERT_MODE_VAL:-self}"
ALLOW_INSECURE="${ALLOW_INSECURE_VAL:-1}"
ARGO_FIXED_DOMAIN="${f_dom}"
CF_ADDR_FIXED="${f_addr}"
SUB_PORT="${sub_port}"
SUB_TOKEN="${sub_token}"
EOF
    chmod 600 "$META_FILE"
    refresh_sub_file

    echo -e "${green}✅ 部署完成！${plain}"
    if [[ -n "$f_dom" && -n "$old_p" && -n "${port:-}" && "$old_p" != "$port" ]]; then
        echo -e "${yellow}⚠️ TCP 端口已从 ${old_p} 改为 ${port}，请到 Cloudflare Zero Trust 把 Public Hostname 回源改成 http://127.0.0.1:${port}${plain}"
    fi

    [[ "$enable_tcp" -eq 1 ]] && echo -e "   TCP: ${cyan}${port}${plain}"
    [[ "$enable_udp" -eq 1 ]] && echo -e "   UDP: ${cyan}${udp_port}${plain}${hop_range:+  跳跃 ${hop_range}}"
    print_links
}

setup_argo() {
    [[ ! -f "$META_FILE" ]] && { echo -e "${red}❌ 请先按 [1] 部署节点！${plain}"; sleep 1.2; return 1; }
    # shellcheck disable=SC1090
    source "$META_FILE"
    if [[ "${ENABLE_TCP:-0}" != "1" || -z "${PORT:-}" ]]; then
        echo -e "${red}❌ Argo 需要 TCP 节点作回源，请先部署含 TCP 的模式${plain}"; sleep 1.5; return 1
    fi
    if [[ ! -x "$BIN_ARGO" ]]; then
        echo -e "${yellow}>>> 正在下载 cloudflared (aegis-argo)...${plain}"
        local arch="amd64"; [[ "$(uname -m)" =~ aarch64|arm64 ]] && arch="arm64"
        curl -fsSL --retry 2 -m 20 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "$BIN_ARGO" && chmod +x "$BIN_ARGO" || { echo -e "${red}❌ 下载失败！${plain}"; return 1; }
    fi
    while true; do
        # shellcheck disable=SC1090
        source "$META_FILE"
        local st="${red}未启用 ❌${plain}"
        systemctl is-active --quiet aegis-argo-fixed && st="${green}运行中 ✅${plain} ${purple}[${ARGO_FIXED_DOMAIN:-未知}]${plain}"
        clear
        echo -e "${cyan}======================================================================${plain}"
        echo -e "              ☁️  Zero Trust 固定隧道配置中心"
        echo -e "${cyan}======================================================================${plain}"
        echo -e "  当前状态 : ${st}"
        echo -e "  回源地址 : ${green}http://127.0.0.1:${PORT}${plain} (CF Zero Trust 后台填写此地址)"
        echo -e "${cyan}----------------------------------------------------------------------${plain}"
        echo -e "  ${cyan}1.${plain} 部署 / 更新 Zero Trust 固定隧道 (支持粘贴整行命令或纯 Token)"
        echo -e "  ${cyan}2.${plain} 切换客户端 CDN 优选地址 (当前: ${cyan}${CF_ADDR_FIXED:-www.visa.com.hk}${plain})"
        echo -e "  ${cyan}3.${plain} ${red}关闭并移除 Argo 固定隧道${plain}"
        echo -e "  ${cyan}0.${plain} 返回主菜单"
        echo -e "${cyan}======================================================================${plain}"
        read -rp "👉 请选择 [0-3]: " m; m="${m//[[:space:]]/}"
        case "$m" in
            1)
                read -rp "👉 请粘贴 Cloudflare Tunnel Token (输入 0 取消): " rt
                [[ "$rt" == "0" || -z "$rt" ]] && continue
                local tk; tk=$(echo "$rt" | grep -oE 'eyJ[A-Za-z0-9_-]{30,}' | head -n1 || true)
                [[ -z "$tk" ]] && { echo -e "${red}❌ Token 格式无效 (需以 eyJ 开头)！${plain}"; sleep 1.5; continue; }
                read -rp "👉 请输入绑定的完整域名 (如 xhttp.domain.com): " rd
                local dm; dm=$(clean_host "$rd")
                [[ -z "$dm" || "$dm" != *.* ]] && { echo -e "${red}❌ 域名无效！${plain}"; sleep 1.5; continue; }
                echo "ARGO_TOKEN=${tk}" > "$WORK_DIR/argo.env" && chmod 600 "$WORK_DIR/argo.env"
                cat > /etc/systemd/system/aegis-argo-fixed.service <<EOF
[Unit]
Description=Aegis-X Argo Fixed Tunnel
After=network.target
[Service]
Type=simple
EnvironmentFile=${WORK_DIR}/argo.env
ExecStart=${BIN_ARGO} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token \${ARGO_TOKEN}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload && systemctl enable --now aegis-argo-fixed >/dev/null 2>&1 && systemctl restart aegis-argo-fixed
                sleep 2
                if ! systemctl is-active --quiet aegis-argo-fixed; then
                    echo -e "${red}❌ 隧道启动失败，请检查 Token！${plain}"; read -rp "按回车继续..." _; continue
                fi
                sed -i "s|^ARGO_FIXED_DOMAIN=.*|ARGO_FIXED_DOMAIN=\"${dm}\"|" "$META_FILE"
                echo -e "${green}✅ 固定隧道已激活: ${dm}${plain}"
                echo -e "${yellow}请确认 Cloudflare Zero Trust Public Hostname 指向 → http://127.0.0.1:${PORT}${plain}"
                refresh_sub_file; print_links; read -rp "👉 按回车继续..." _ ;;
            2)
                echo -e "\n  ${green}1.${plain} www.visa.com.hk  ${green}2.${plain} www.visa.com.sg  ${green}3.${plain} cloudflare-ech.com  ${green}4.${plain} www.wto.org  ${purple}5.${plain} 自定义  ${cyan}0.${plain} 返回"
                read -rp "👉 请选择优选 [0-5，回车默认 1]: " ac; ac="${ac//[[:space:]]/}"
                local nf="www.visa.com.hk"
                case "${ac:-1}" in
                    0) continue ;;
                    1) nf="www.visa.com.hk" ;; 2) nf="www.visa.com.sg" ;; 3) nf="cloudflare-ech.com" ;; 4) nf="www.wto.org" ;;
                    5) read -rp "👉 输入优选 IP 或域名: " cf; nf=$(clean_host "$cf"); [[ -z "$nf" || "$nf" != *.* ]] && nf="www.visa.com.hk" ;;
                    *) echo -e "${red}❌ 输入无效！${plain}"; sleep 1; continue ;;
                esac
                sed -i "s|^CF_ADDR_FIXED=.*|CF_ADDR_FIXED=\"${nf}\"|" "$META_FILE"
                echo -e "${green}✅ 优选已更新为: ${nf}${plain}"
                refresh_sub_file; print_links; read -rp "👉 按回车继续..." _ ;;
            3)
                systemctl disable --now aegis-argo-fixed 2>/dev/null || true
                pkill -9 -f "$BIN_ARGO" 2>/dev/null || true
                rm -f /etc/systemd/system/aegis-argo-fixed.service "$WORK_DIR/argo.env" && systemctl daemon-reload
                sed -i 's|^ARGO_FIXED_DOMAIN=.*|ARGO_FIXED_DOMAIN=""|' "$META_FILE"
                refresh_sub_file
                echo -e "${green}✅ Argo 隧道已移除。${plain}"; sleep 1.2 ;;
            0) return 0 ;;
            *) echo -e "${red}❌ 非法输入！请输入 0-3！${plain}"; sleep 1 ;;
        esac
    done
}

print_links() {
    [[ ! -f "$META_FILE" ]] && { echo -e "${red}❌ 尚未部署节点！${plain}"; return 0; }
    # shellcheck disable=SC1090
    source "$META_FILE"
    refresh_sub_file
    local ip pe hop_q sni_host fa dl ul fl
    ip=$(curl -fsSL4 -m 3 icanhazip.com 2>/dev/null || curl -fsSL4 -m 3 ip.sb 2>/dev/null || echo "YOUR_IP")
    pe="${XHTTP_PATH//\//%2F}"

    echo -e "\n${cyan}================ [ 🖨️ VLESS-XHTTP 节点提取中心 ] =================${plain}"

    if [[ "${ENABLE_TCP:-0}" == "1" && -n "${PORT:-}" ]]; then
        dl="vless://${UUID}@${ip}:${PORT}?encryption=${ENC_KEY}&flow=xtls-rprx-vision&security=none&type=xhttp&path=${pe}&mode=auto#vless-xhttp-tcp"
        echo -e "\n${purple}【 TCP 直连 | 端口: ${PORT} 】${plain}\n${yellow}${dl}${plain}\n"
        maybe_qr "$dl"
    fi

    if [[ "${ENABLE_UDP:-0}" == "1" && -n "${UDP_PORT:-}" ]]; then
        hop_q=""; [[ -n "${HOP_RANGE:-}" ]] && hop_q="&mport=${HOP_RANGE}"
        sni_host="${UDP_SNI:-aegis-x.local}"
        insecure_q=""; [[ "${ALLOW_INSECURE:-1}" == "1" ]] && insecure_q="&allowInsecure=1"
        ul="vless://${UUID}@${ip}:${UDP_PORT}?encryption=${ENC_KEY}&security=tls&sni=${sni_host}&fp=chrome&alpn=h3&type=xhttp&path=${pe}&mode=stream-one${insecure_q}${hop_q}#vless-xhttp-udp"
        echo -e "\n${purple}【 UDP H3 | 端口: ${UDP_PORT}${HOP_RANGE:+ | 跳跃: ${HOP_RANGE}} | 证书: ${CERT_MODE:-self} 】${plain}\n${yellow}${ul}${plain}\n"
        echo -e "${yellow}   SNI=${sni_host} · mode=stream-one · 无 Vision${insecure_q:+ · allowInsecure}${plain}"
        maybe_qr "$ul"
    fi

    if systemctl is-active --quiet aegis-argo-fixed && [[ -n "${ARGO_FIXED_DOMAIN:-}" ]]; then
        fa="${CF_ADDR_FIXED:-www.visa.com.hk}"
        fl="vless://${UUID}@${fa}:443?encryption=${ENC_KEY}&flow=xtls-rprx-vision&security=tls&sni=${ARGO_FIXED_DOMAIN}&host=${ARGO_FIXED_DOMAIN}&alpn=h2&fp=chrome&type=xhttp&path=${pe}&mode=packet-up#vless-xhttp-argo"
        echo -e "\n${purple}【 Argo | 优选: ${fa} | SNI: ${ARGO_FIXED_DOMAIN} 】${plain}\n${purple}${fl}${plain}\n"
        maybe_qr "$fl"
    fi

    echo -e "\n${cyan}----------------------------------------------------------------------${plain}"
    if [[ -n "${SUB_PORT:-}" && -n "${SUB_TOKEN:-}" ]]; then
        echo -e "${green}>>> 订阅链接（添加后只需「更新订阅」）：${plain}"
        echo -e "${blue}http://${ip}:${SUB_PORT}/${SUB_TOKEN}${plain}"
        echo -e "${yellow}    内容为每行一条 vless:// ；要 Base64 用下方备用串${plain}"
    fi
    echo -e "\n${yellow}>>> 备用：聚合 Base64：${plain}"
    if [[ -s "$SUB_FILE" ]]; then
        echo -e "${blue}$(base64 -w 0 < "$SUB_FILE" 2>/dev/null || base64 < "$SUB_FILE" | tr -d '\n')${plain}\n"
    fi
}

update_cores() {
    local need_exec=0 r_ver=""
    if curl -fsSL -m 5 "$SCRIPT_URL" -o /tmp/ax_new.sh 2>/dev/null && bash -n /tmp/ax_new.sh 2>/dev/null; then
        r_ver=$(grep -E '^ax_VERSION=' /tmp/ax_new.sh | head -n1 | cut -d'"' -f2)
        if ! cmp -s /tmp/ax_new.sh "$WORK_DIR/ax.sh" 2>/dev/null; then
            mv -f /tmp/ax_new.sh "$WORK_DIR/ax.sh" && chmod +x "$WORK_DIR/ax.sh"
            ln -sf "$WORK_DIR/ax.sh" "$SHORTCUT"
            echo -e "${green}✅ 面板脚本已同步${r_ver:+至 v${r_ver}}${plain}"
            need_exec=1
        else
            echo -e "${green}✅ 面板脚本已是最新${r_ver:+ (v${r_ver})}${plain}"
            rm -f /tmp/ax_new.sh
        fi
    else
        echo -e "${yellow}⚠️ 无法拉取远程脚本，跳过面板更新${plain}"
        rm -f /tmp/ax_new.sh
    fi
    local lv="未安装" rv=""
    [[ -x "$BIN_XRAY" ]] && lv=$("$BIN_XRAY" version 2>/dev/null | head -n1 | awk '{print $2}')
    rv=$(curl -fsSL -m 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
    echo -e "当前内核: ${purple}v${lv}${plain} | 最新内核: ${green}v${rv:-未知}${plain}"
    if [[ -z "$rv" ]]; then
        echo -e "${yellow}⚠️ 无法获取最新内核版本，跳过${plain}"
    elif [[ "$lv" == "$rv" ]]; then
        echo -e "${green}✅ Xray-core 已是最新版本，无需更新！${plain}"
    else
        install_xray && systemctl restart aegis-xray 2>/dev/null && echo -e "${green}✅ 内核更新完毕！${plain}"
    fi
    if [[ "$need_exec" -eq 1 ]]; then
        echo -e "${green}正在重启界面...${plain}"
        sleep 1
        exec "$WORK_DIR/ax.sh"
    fi
    sleep 1
}

inspect_logs() {
    echo -e "\n${cyan}=== [1. 进程与端口监听] ===${plain}"
    ps -ef | grep -E "[a]egis-xray|[a]egis-argo|[a]egis-sub" || echo -e "${red}无运行进程${plain}"
    echo -e "\n${cyan}=== [2. Xray 最近 10 条日志] ===${plain}"
    journalctl -u aegis-xray -n 10 --no-pager || true
    systemctl is-active --quiet aegis-argo-fixed && echo -e "\n${cyan}=== [3. Argo] ===${plain}" && journalctl -u aegis-argo-fixed -n 10 --no-pager || true
    systemctl is-active --quiet aegis-sub && echo -e "\n${cyan}=== [4. 订阅服务] ===${plain}" && systemctl status aegis-sub --no-pager -l | head -n 12 || true
}

nuke_all() {
    echo -e "\n${yellow}⚠️ 确认彻底卸载 Aegis-X (ax)？(不影响 BBR 与其他服务)${plain}"
    read -rp "👉 确认卸载？[y/N]: " cf
    [[ "${cf//[[:space:]]/}" != [yY] ]] && return 0
    # shellcheck disable=SC1090
    if [[ -f "$META_FILE" ]]; then
        source "$META_FILE"
        manage_port close "${PORT:-}" tcp
        manage_port close "${UDP_PORT:-}" udp
        [[ -n "${HOP_RANGE:-}" && -n "${UDP_PORT:-}" ]] && manage_hop_redirect close "$UDP_PORT" "$HOP_RANGE" && manage_port close "$HOP_RANGE" udp
        stop_sub_server "${SUB_PORT:-}"
    fi
    for s in aegis-xray aegis-argo aegis-argo-temp aegis-argo-fixed aegis-sub; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/${s}.service"
    done
    systemctl daemon-reload
    pkill -9 -f "$BIN_XRAY" 2>/dev/null || true
    pkill -9 -f "$BIN_ARGO" 2>/dev/null || true
    rm -rf "$WORK_DIR" "$BIN_XRAY" "$BIN_ARGO" "$SHORTCUT" /tmp/ax_*
    echo -e "${green}✅ ax 已彻底无痕卸载！${plain}"; exit 0
}

env_guard
UPDATE_CHECKED=0
update_tip="${green}✅ ax 已是最新版 (v${ax_VERSION})${plain}"
xray_tip="${yellow}检测中...${plain}"
while true; do
    st_x="${red}未运行 ❌${plain}"; st_a="${yellow}未启用 ○${plain}"; ver_x="未安装"; p_info="-----"
    [[ -x "$BIN_XRAY" ]] && ver_x=$("$BIN_XRAY" version 2>/dev/null | head -n1 | awk '{print $2}')
    systemctl is-active --quiet aegis-xray && st_x="${green}运行中 ✅${plain}"
    # shellcheck disable=SC1090
    [[ -f "$META_FILE" ]] && source "$META_FILE" && p_info="${PORT:-${UDP_PORT:------}}"
    systemctl is-active --quiet aegis-argo-fixed && st_a="${green}已连接 ✅${plain} ${purple}[${ARGO_FIXED_DOMAIN:-ZeroTrust}]${plain}"

    if [[ "$UPDATE_CHECKED" -eq 0 ]]; then
        update_tip="${green}✅ ax 已是最新版 (v${ax_VERSION})${plain}"
        if curl -fsSL -m 3 "$SCRIPT_URL" -o /tmp/ax_check.sh 2>/dev/null; then
            r_ver=$(grep -E '^ax_VERSION=' /tmp/ax_check.sh 2>/dev/null | head -n1 | cut -d'"' -f2)
            if ! cmp -s /tmp/ax_check.sh "$WORK_DIR/ax.sh" 2>/dev/null; then
                update_tip="${yellow}🔥 发现脚本有更新${r_ver:+ (远程 v${r_ver})}，请按 [5] 更新${plain}"
            fi
            rm -f /tmp/ax_check.sh
        fi
        local_lv="未安装"
        [[ -x "$BIN_XRAY" ]] && local_lv=$("$BIN_XRAY" version 2>/dev/null | head -n1 | awk '{print $2}')
        remote_lv=$(curl -fsSL -m 3 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
        if [[ -n "$remote_lv" && "$local_lv" != "未安装" && "$local_lv" != "$remote_lv" ]]; then
            xray_tip="${yellow}🔥 Xray 有新版本 v${remote_lv}（当前 v${local_lv}），请按 [5] 更新${plain}"
        elif [[ -n "$remote_lv" && "$local_lv" == "$remote_lv" ]]; then
            xray_tip="${green}✅ Xray 已是最新 (v${local_lv})${plain}"
        else
            xray_tip="${yellow}检测中...${plain}"
        fi
        UPDATE_CHECKED=1
    fi

    clear
    echo -e "${cyan}██╗   ██╗███████╗██╗      ██████╗ ██╗  ██╗${plain}"
    echo -e "${cyan}██║   ██║██╔════╝██║     ██╔═══██╗╚██╗██╔╝${plain}"
    echo -e "${blue}██║   ██║█████╗  ██║     ██║   ██║ ╚███╔╝ ${plain}"
    echo -e "${blue}╚██╗ ██╔╝██╔══╝  ██║     ██║   ██║ ██╔██╗ ${plain}"
    echo -e "${purple} ╚████╔╝ ███████╗███████╗╚██████╔╝██╔╝ ██╗${plain}"
    echo -e "${purple}  ╚═══╝  ╚══════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝${plain}"
    echo -e "${cyan}======================================================================${plain}"
    echo -e "        🚀 Aegis-X (ax) 终极控制枢纽 V${ax_VERSION} 🚀        "
    echo -e "${cyan}======================================================================${plain}"
    echo -e "   👨‍💻 作者GitHub项目 : ${blue}github.com/pwenxiang51-wq${plain}"
    echo -e "   📝 作者Velo.x博客 : ${blue}222382.xyz${plain}"
    echo -e "   ✈️ 作者Telegram   : ${blue}@Velox95${plain}"
    echo -e "   ⚡ 脚本状态: ${update_tip:-${yellow}检测中...${plain}}"
    echo -e "   ⚡ 内核状态: ${xray_tip:-${yellow}检测中...${plain}}"
    echo -e "${cyan}======================================================================${plain}"
    echo -e "⚙️  ${yellow}核心状态:${plain} Xray ${cyan}v${ver_x}${plain} | 端口: ${cyan}${p_info}${plain} | 加速: $(get_bbr_stat)"
    echo -e "📡  ${yellow}运行状态:${plain} Xray: ${st_x}  | Argo: ${st_a}"
    echo -e "${cyan}----------------------------------------------------------------------${plain}"
    echo -e "  ${cyan}1.${plain} ➕ 部署/重置 VLESS-XHTTP            ${green}[TCP/UDP/双开 · 完整ML-KEM]${plain}"
    echo -e "  ${cyan}2.${plain} ☁️ 挂载 Zero Trust 固定隧道         ${purple}[CDN 优选防封复活甲🛡️]${plain}"
    echo -e "  ${cyan}3.${plain} 🖨️ ${cyan}一键提取节点与订阅链接${plain}           ${green}[HTTP订阅 · 可选二维码]${plain}"
    echo -e "  ${cyan}4.${plain} 📋 查看服务状态与运行日志           ${yellow}[进程/端口/连接诊断]${plain}"
    echo -e "  ${cyan}5.${plain} 🔄 检查并更新脚本与 Xray 内核       ${blue}[版本比对与语法预检]${plain}"
    echo -e "${cyan}----------------------------------------------------------------------${plain}"
    echo -e "  ${cyan}9.${plain} 🗑️ ${red}彻底粉碎卸载 (零误伤其他服务)${plain}    |  ${cyan}0.${plain} 🔙 ${cyan}退出终端 (快捷键: ax)${plain}"
    echo -e "${cyan}======================================================================${plain}"
    read -rp "👉 执行指令 [0-5, 9]: " ch; ch="${ch//[[:space:]]/}"
    case "$ch" in
        1) deploy_xhttp; read -rp "👉 按回车返回..." _ ;;
        2) setup_argo ;;
        3) print_links; read -rp "👉 按回车返回..." _ ;;
        4) inspect_logs; read -rp "👉 按回车返回..." _ ;;
        5) update_cores; UPDATE_CHECKED=0 ;;
        9) nuke_all ;;
        0) exit 0 ;;
        *) echo -e "${red}❌ 无效指令！请输入 0-5 或 9！${plain}"; sleep 1 ;;
    esac
done
