#!/bin/bash
export LANG=en_US.UTF-8
set -uo pipefail
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; cyan='\033[0;36m'; blue='\033[0;94m'; purple='\033[1;35m'; plain='\033[0m'
ax_VERSION="1.0.6"
SCRIPT_URL="https://raw.githubusercontent.com/pwenxiang51-wq/aegis-x/main/ax.sh"
WORK_DIR="/etc/aegis-x"
BIN_XRAY="/usr/local/bin/aegis-xray"
BIN_ARGO="/usr/local/bin/aegis-argo"
SHORTCUT="/usr/local/bin/ax"
CONF_FILE="${WORK_DIR}/config.json"
META_FILE="${WORK_DIR}/node.env"
SUB_FILE="${WORK_DIR}/links.txt"
[[ $EUID -ne 0 ]] && echo -e "${red}❌ 错误: 请使用 root 用户运行！${plain}" && exit 1
trap 'rm -f /tmp/ax_* "${CONF_FILE}.tmp" 2>/dev/null; echo -e "\n${yellow}⚠️ 操作已取消。${plain}"; exit 130' INT TERM
clean_host() {
    local v="${1//[[:space:]]/}"
    v="${v#http://}"; v="${v#https://}"; echo "${v%%/*}"
}
env_guard() {
    mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"
    [[ -f "$0" && "$(realpath "$0" 2>/dev/null)" != "$WORK_DIR/ax.sh" ]] && cp -f "$0" "$WORK_DIR/ax.sh" 2>/dev/null || true
    [[ ! -s "$WORK_DIR/ax.sh" ]] && curl -fsSL -m 10 "$SCRIPT_URL" -o "$WORK_DIR/ax.sh" 2>/dev/null || true
    chmod +x "$WORK_DIR/ax.sh" 2>/dev/null && ln -sf "$WORK_DIR/ax.sh" "$SHORTCUT"
    local miss=()
    for c in curl jq unzip qrencode xxd; do ! command -v "$c" &>/dev/null && miss+=("$c"); done
    ! command -v ss &>/dev/null && miss+=("iproute2")
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
manage_port() {
    local act="$1" p="${2:-}"
    [[ -z "$p" ]] && return 0
    if [[ "$act" == "open" ]]; then
        command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    else
        command -v ufw &>/dev/null && ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
        iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
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
# 可靠提取 ML-KEM-768（后量子）密钥对，取最后一套
gen_vlessenc() {
    local raw dec enc
    raw=$("$BIN_XRAY" vlessenc 2>/dev/null) || return 1
    dec=$(printf '%s\n' "$raw" | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n1)
    enc=$(printf '%s\n' "$raw" | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n1)
    [[ -n "$dec" && -n "$enc" && "$dec" == mlkem768* && "$enc" == mlkem768* ]] || return 1
    printf '%s\n%s\n' "$dec" "$enc"
}
deploy_xhttp() {
    local old_p="" f_dom="" f_addr="www.visa.com.hk"
    # shellcheck disable=SC1090
    [[ -f "$META_FILE" ]] && source "$META_FILE" && old_p="${PORT:-}" && f_dom="${ARGO_FIXED_DOMAIN:-}" && f_addr="${CF_ADDR_FIXED:-www.visa.com.hk}"
    if systemctl is-active --quiet aegis-xray && [[ -n "$old_p" ]]; then
        read -rp "⚠️ 节点已在运行 (端口: ${old_p})，确认重置配置？[y/N]: " rc
        [[ "${rc//[[:space:]]/}" != [yY] ]] && return 0
    fi
    ensure_bbr
    [[ ! -x "$BIN_XRAY" ]] && { install_xray || return 1; }
    read -rp "👉 请输入监听端口 [1024-65535，回车随机]: " in_p
    in_p="${in_p//[[:space:]]/}"
    local port=""
    if [[ "$in_p" =~ ^[0-9]+$ ]] && (( in_p >= 1024 && in_p <= 65535 )) && { [[ "$in_p" == "$old_p" ]] || ! ss -tulpn 2>/dev/null | grep -qE ":${in_p}\b"; }; then
        port="$in_p"
    else
        [[ -n "$in_p" ]] && echo -e "${yellow}⚠️ 端口无效或已占用，自动切换随机端口...${plain}"
        while true; do port=$(shuf -i 20000-58000 -n 1); ! ss -tulpn 2>/dev/null | grep -qE ":${port}\b" && break; done
    fi
    local uuid path keys dec enc
    uuid=$("$BIN_XRAY" uuid)
    # 路径：UUID 前 12 位 + 4 位随机，降低可预测性
    path="/$(tr -d '-' <<<"$uuid" | cut -c1-12)$(head -c 2 /dev/urandom | xxd -p 2>/dev/null || echo "ax")"
    keys=$(gen_vlessenc) || { echo -e "${red}❌ 生成 ML-KEM-768 密钥失败！${plain}"; return 1; }
    dec=$(sed -n '1p' <<<"$keys")
    enc=$(sed -n '2p' <<<"$keys")
    # 直连场景 security=none，不使用 flow（Vision 需要 TLS/REALITY）
    cat <<EOF > "${CONF_FILE}.tmp"
{"log":{"loglevel":"warning"},"inbounds":[{"tag":"vless-xhttp-in","port":${port},"protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"${dec}"},"streamSettings":{"network":"xhttp","xhttpSettings":{"path":"${path}","mode":"auto"},"security":"none","sockopt":{"tcpFastOpen":true}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOF
    jq . "${CONF_FILE}.tmp" > "${CONF_FILE}.tmp2" && mv -f "${CONF_FILE}.tmp2" "${CONF_FILE}.tmp"
    if ! "$BIN_XRAY" run -test -format json -c "${CONF_FILE}.tmp" >/dev/null 2>&1; then
        rm -f "${CONF_FILE}.tmp"; echo -e "${red}❌ JSON 预检失败，已阻断写入！${plain}"; return 1
    fi
    mv -f "${CONF_FILE}.tmp" "$CONF_FILE" && chmod 600 "$CONF_FILE"
    cat <<EOF > /etc/systemd/system/aegis-xray.service
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
    [[ -n "$old_p" && "$old_p" != "$port" ]] && manage_port close "$old_p"
    manage_port open "$port"
    cat <<EOF > "$META_FILE"
PORT="${port}"
UUID="${uuid}"
XHTTP_PATH="${path}"
ENC_KEY="${enc}"
DEC_KEY="${dec}"
ARGO_FIXED_DOMAIN="${f_dom}"
CF_ADDR_FIXED="${f_addr}"
EOF
    chmod 600 "$META_FILE"
    echo -e "${green}✅ VLESS-XHTTP 已启动 (端口: ${port})！${plain}"
    print_links
}
setup_argo() {
    [[ ! -f "$META_FILE" ]] && { echo -e "${red}❌ 请先按 [1] 部署节点！${plain}"; sleep 1.2; return 1; }
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
        echo -e "  回源地址 : ${green}HTTP://127.0.0.1:${PORT}${plain} (CF Zero Trust 后台填写此地址)"
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
                cat <<EOF > /etc/systemd/system/aegis-argo-fixed.service
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
                print_links; read -rp "👉 按回车继续..." _ ;;
            2)
                echo -e "\n  ${green}1.${plain} www.visa.com.hk  ${green}2.${plain} www.visa.com.sg  ${green}3.${plain} cloudflare-ech.com  ${green}4.${plain} www.wto.org  ${purple}5.${plain} 自定义"
                read -rp "👉 请选择优选 [1-5, 回车默认 1]: " ac; ac="${ac//[[:space:]]/}"
                local nf="www.visa.com.hk"
                case "${ac:-1}" in
                    1) nf="www.visa.com.hk" ;; 2) nf="www.visa.com.sg" ;; 3) nf="cloudflare-ech.com" ;; 4) nf="www.wto.org" ;;
                    5) read -rp "👉 输入优选 IP 或域名: " cf; nf=$(clean_host "$cf"); [[ -z "$nf" || "$nf" != *.* ]] && nf="www.visa.com.hk" ;;
                    *) echo -e "${red}❌ 输入无效！${plain}"; sleep 1; continue ;;
                esac
                sed -i "s|^CF_ADDR_FIXED=.*|CF_ADDR_FIXED=\"${nf}\"|" "$META_FILE"
                echo -e "${green}✅ 优选已更新为: ${nf}${plain}"
                print_links; read -rp "👉 按回车继续..." _ ;;
            3)
                systemctl disable --now aegis-argo-fixed 2>/dev/null || true
                pkill -9 -f "$BIN_ARGO" 2>/dev/null || true
                rm -f /etc/systemd/system/aegis-argo-fixed.service "$WORK_DIR/argo.env" && systemctl daemon-reload
                sed -i 's|^ARGO_FIXED_DOMAIN=.*|ARGO_FIXED_DOMAIN=""|' "$META_FILE"
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
    local ip; ip=$(curl -fsSL4 -m 3 icanhazip.com 2>/dev/null || curl -fsSL4 -m 3 ip.sb 2>/dev/null || echo "YOUR_IP")
    local pe="${XHTTP_PATH//\//%2F}"
    # 直连：security=none，无 flow
    local dl="vless://${UUID}@${ip}:${PORT}?encryption=${ENC_KEY}&security=none&type=xhttp&path=${pe}&mode=auto#vless-xhttp"
    echo -e "\n${cyan}================ [ 🖨️ VLESS-XHTTP 节点提取中心 ] =================${plain}"
    echo -e "\n${purple}【 1. VLESS-XHTTP 直连 | 端口: ${PORT} 】${plain}\n${yellow}${dl}${plain}\n"
    echo "$dl" | qrencode -t UTF8
    echo "$dl" > "$SUB_FILE" && chmod 600 "$SUB_FILE"
    if systemctl is-active --quiet aegis-argo-fixed && [[ -n "${ARGO_FIXED_DOMAIN:-}" ]]; then
        local fa="${CF_ADDR_FIXED:-www.visa.com.hk}"
        # Argo：security=tls，mode=packet-up（过 CDN 兼容性最好），无 flow
        local fl="vless://${UUID}@${fa}:443?encryption=${ENC_KEY}&security=tls&sni=${ARGO_FIXED_DOMAIN}&host=${ARGO_FIXED_DOMAIN}&alpn=h2&fp=chrome&type=xhttp&path=${pe}&mode=packet-up#vless-xhttp-argo"
        echo -e "\n${purple}【 2. VLESS-XHTTP-Argo | 优选: ${fa} | SNI: ${ARGO_FIXED_DOMAIN} 】${plain}\n${purple}${fl}${plain}\n"
        echo "$fl" | qrencode -t UTF8
        echo "$fl" >> "$SUB_FILE"
    fi
    echo -e "\n${cyan}----------------------------------------------------------------------${plain}"
    echo -e "${yellow}>>> 🔗 聚合 Base64 订阅 (复制下方蓝字进 v2rayN 按 Ctrl+V 导入)：${plain}"
    echo -e "${blue}$(base64 -w 0 < "$SUB_FILE")${plain}\n"
}
update_cores() {
    # 1. 顺手同步 GitHub 上的最新 ax.sh 脚本 (语法校验通过才覆盖)
    if curl -fsSL -m 5 "$SCRIPT_URL" -o /tmp/ax_new.sh 2>/dev/null && bash -n /tmp/ax_new.sh 2>/dev/null; then
        local r_ver; r_ver=$(grep -E '^ax_VERSION=' /tmp/ax_new.sh | head -n1 | cut -d'"' -f2)
        if [[ -n "$r_ver" && "$r_ver" != "$ax_VERSION" ]]; then
            mv -f /tmp/ax_new.sh "$WORK_DIR/ax.sh" && chmod +x "$WORK_DIR/ax.sh"
            echo -e "${green}✅ 面板脚本已同步升级至 v${r_ver}！${plain}"
        fi
    fi
    rm -f /tmp/ax_new.sh
    # 2. 检查并更新 Xray-core 内核
    local lv="未安装" rv=""
    [[ -x "$BIN_XRAY" ]] && lv=$("$BIN_XRAY" version 2>/dev/null | head -n1 | awk '{print $2}')
    rv=$(curl -fsSL -m 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
    echo -e "\n当前内核: ${purple}v${lv}${plain} | 最新内核: ${green}v${rv:-未知}${plain}"
    [[ -n "$rv" && "$lv" == "$rv" ]] && { echo -e "${green}✅ Xray-core 已是最新版本，无需更新！${plain}"; return 0; }
    install_xray && systemctl restart aegis-xray 2>/dev/null && echo -e "${green}✅ 内核更新完毕！${plain}"
}
inspect_logs() {
    echo -e "\n${cyan}=== [1. 进程与端口监听] ===${plain}"
    ps -ef | grep -E "[a]egis-xray|[a]egis-argo" || echo -e "${red}无运行进程${plain}"
    echo -e "\n${cyan}=== [2. Xray 最近 10 条日志] ===${plain}"
    journalctl -u aegis-xray -n 10 --no-pager || true
    systemctl is-active --quiet aegis-argo-fixed && echo -e "\n${cyan}=== [3. Argo 最近 10 条日志] ===${plain}" && journalctl -u aegis-argo-fixed -n 10 --no-pager || true
}
nuke_all() {
    echo -e "\n${yellow}⚠️ 确认彻底卸载 Aegis-X (ax)？(不影响 BBR 与其他服务)${plain}"
    read -rp "👉 确认卸载？[y/N]: " cf
    [[ "${cf//[[:space:]]/}" != [yY] ]] && return 0
    # shellcheck disable=SC1090
    [[ -f "$META_FILE" ]] && source "$META_FILE" && manage_port close "${PORT:-}"
    for s in aegis-xray aegis-argo aegis-argo-temp aegis-argo-fixed; do
        systemctl stop "$s" 2>/dev/null || true; systemctl disable "$s" 2>/dev/null || true; rm -f "/etc/systemd/system/${s}.service"
    done
    systemctl daemon-reload
    pkill -9 -f "$BIN_XRAY" 2>/dev/null || true; pkill -9 -f "$BIN_ARGO" 2>/dev/null || true
    rm -rf "$WORK_DIR" "$BIN_XRAY" "$BIN_ARGO" "$SHORTCUT" /tmp/ax_*
    echo -e "${green}✅ ax 已彻底无痕卸载！${plain}"; exit 0
}
env_guard
while true; do
    st_x="${red}未运行 ❌${plain}"; st_a="${yellow}未启用 ○${plain}"; ver_x="未安装"; p_info="-----"
    [[ -x "$BIN_XRAY" ]] && ver_x=$("$BIN_XRAY" version 2>/dev/null | head -n1 | awk '{print $2}')
    systemctl is-active --quiet aegis-xray && st_x="${green}运行中 ✅${plain}"
    # shellcheck disable=SC1090
    [[ -f "$META_FILE" ]] && source "$META_FILE" && p_info="${PORT:-'-----'}"
    systemctl is-active --quiet aegis-argo-fixed && st_a="${green}已连接 ✅${plain} ${purple}[${ARGO_FIXED_DOMAIN:-ZeroTrust}]${plain}"
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
    echo -e "${cyan}======================================================================${plain}"
    echo -e "⚙️  ${yellow}核心状态:${plain} Xray ${cyan}v${ver_x}${plain} | 端口: ${cyan}${p_info}${plain} | 加速: $(get_bbr_stat)"
    echo -e "📡  ${yellow}运行状态:${plain} Xray: ${st_x}  | Argo: ${st_a}"
    echo -e "${cyan}----------------------------------------------------------------------${plain}"
    echo -e "  ${cyan}1.${plain} ➕ 部署/重置 VLESS-XHTTP            ${green}[ML-KEM-768 抗量子✨]${plain}"
    echo -e "  ${cyan}2.${plain} ☁️ 挂载 Zero Trust 固定隧道          ${purple}[CDN 优选防封复活甲🛡️]${plain}"
    echo -e "  ${cyan}3.${plain} 🖨️ ${cyan}一键提取节点与二维码${plain}             ${green}[含聚合 Base64 订阅]${plain}"
    echo -e "  ${cyan}4.${plain} 📋 查看服务状态与运行日志           ${yellow}[进程/端口/连接诊断]${plain}"
    echo -e "  ${cyan}5.${plain} 🔄 检查并更新 Xray-core 内核        ${blue}[版本比对与语法预检]${plain}"
    echo -e "${cyan}----------------------------------------------------------------------${plain}"
    echo -e "  ${cyan}9.${plain} 🗑️ ${red}彻底粉碎卸载 (零误伤其他服务)${plain}    |  ${cyan}0.${plain} 🔙 ${cyan}退出终端 (快捷键: ax)${plain}"
    echo -e "${cyan}======================================================================${plain}"
    read -rp "👉 执行指令 [0-5, 9]: " ch; ch="${ch//[[:space:]]/}"
    case "$ch" in
        1) deploy_xhttp; read -rp "👉 按回车返回..." _ ;;
        2) setup_argo ;;
        3) print_links; read -rp "👉 按回车返回..." _ ;;
        4) inspect_logs; read -rp "👉 按回车返回..." _ ;;
        5) update_cores; read -rp "👉 按回车返回..." _ ;;
        9) nuke_all ;;
        0) exit 0 ;;
        *) echo -e "${red}❌ 无效指令！请输入 0-5 或 9！${plain}"; sleep 1 ;;
    esac
done
