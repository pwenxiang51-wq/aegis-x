# 🛡️ Aegis-X (`ax`)

极简高阶 `VLESS-XHTTP` 单节点部署工具 | 原生 `ML-KEM-768` 抗量子加密 + `XHTTP/3` + Cloudflare Tunnels。

## 🚀 一键安装

~~~bash
bash <(curl -fsSL https://raw.githubusercontent.com/pwenxiang51-wq/aegis-x/main/ax.sh)
~~~

> 快捷指令：安装后在终端输入 **`ax`** 即可呼出控制面板。

## ⚡ 核心架构

* **直连 TCP**：`VLESS` + `XHTTP` + `XTLS-Vision` + `ML-KEM-768`
* **直连 UDP/H3**：`VLESS` + `XHTTP/3 (QUIC)` + `ML-KEM-768` + 端口跳跃，证书只能用 Let's Encrypt 真证书（sslip.io + LE 或自有域名 + LE；自签不通，已拿掉）
* **固定隧道**：`VLESS` + `XHTTP (packet-up)` + `Cloudflare Tunnels (HTTP/2)`
* **订阅**：菜单 `3` 一键提取节点与聚合订阅链接
* **卸载**：菜单 `9` 彻底清除（含 acme.sh 与续签 cron）

## 🔗 链接

* **Blog**：[222382.xyz](https://222382.xyz) | **Telegram**：[@Velox95](https://t.me/Velox95)
