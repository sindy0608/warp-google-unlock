#!/bin/bash

# WARP 一键脚本 - 使用 Cloudflare 官方客户端
# Google + 中国大陆 HTTPS(443) 流量通过 WARP
# 修正版：redsocks 仅由 systemd 管理，避免重复启动导致 Address already in use

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║   🌐 WARP 一键脚本 - Google + 中国大陆解锁 (仅443) 🌐          ║"
    echo "║     使用 Cloudflare 官方客户端(修正redsocks )                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
    CODENAME=$VERSION_CODENAME
else
    echo -e "${RED}无法检测系统${NC}"
    exit 1
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

install_warp() {
    echo -e "\n${CYAN}[1/3] 安装 Cloudflare WARP 官方客户端...${NC}"

    case $OS in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y gnupg curl wget lsb-release >/dev/null 2>&1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" \
                > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo << 'EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
            if command -v dnf &>/dev/null; then
                dnf install -y cloudflare-warp
            else
                yum install -y cloudflare-warp
            fi
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            exit 1
            ;;
    esac

    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}WARP 安装失败${NC}"
        exit 1
    fi

    systemctl enable warp-svc 2>/dev/null || true
    systemctl restart warp-svc 2>/dev/null || true

    echo -e "${GREEN}✓ WARP 客户端已安装${NC}"
}

configure_warp() {
    echo -e "\n${CYAN}[2/3] 配置 WARP...${NC}"

    echo "正在注册设备..."
    warp-cli --accept-tos registration new 2>/dev/null \
        || warp-cli --accept-tos register 2>/dev/null \
        || true

    warp-cli --accept-tos mode proxy 2>/dev/null \
        || warp-cli mode proxy 2>/dev/null \
        || true

    warp-cli --accept-tos proxy port 40000 2>/dev/null \
        || warp-cli proxy port 40000 2>/dev/null \
        || true

    echo "正在连接 WARP..."
    warp-cli --accept-tos connect 2>/dev/null \
        || warp-cli connect 2>/dev/null \
        || true

    sleep 3

    STATUS=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null)
    echo -e "状态: ${GREEN}$STATUS${NC}"
    echo -e "${GREEN}✓ WARP 配置完成${NC}"
}

setup_transparent_proxy() {
    echo -e "\n${CYAN}[3/3] 配置透明代理规则...${NC}"

    echo "配置 IPv6 规则..."
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true

    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    case $OS in
        ubuntu|debian)
            apt-get install -y redsocks iptables ipset curl >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables ipset curl >/dev/null 2>&1
            else
                yum install -y redsocks iptables ipset curl >/dev/null 2>&1
            fi
            ;;
    esac

    # 写入 redsocks 配置。
    # 重点：redsocks 不再由 warp-google 脚本直接启动，而是只交给 systemd 管理。
    cat > /etc/redsocks.conf << 'EOF'
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}
EOF

    # 清理旧脚本可能遗留的“野生” redsocks 进程，然后让 systemd 正式接管。
    # 这里只在安装/修复阶段执行一次，不会放进日常 start/restart 逻辑。
    pkill -x redsocks 2>/dev/null || true
    sleep 1

    systemctl daemon-reload
    systemctl enable redsocks 2>/dev/null || true
    systemctl reset-failed redsocks 2>/dev/null || true
    systemctl restart redsocks

    if ! systemctl is-active --quiet redsocks; then
        echo -e "${RED}✗ redsocks 启动失败${NC}"
        systemctl status redsocks --no-pager -l
        exit 1
    fi

    cat > /usr/local/bin/warp-google << 'SCRIPT'
#!/bin/bash

GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

CN_IP_CACHE="/etc/warp/cn_ip.txt"

download_cn_ips() {
    mkdir -p /etc/warp
    echo "下载中国大陆 IP 列表 (APNIC 官方源)..."

    local tmp="/tmp/cn_ip_tmp.txt"

    if curl -sS --max-time 60 https://ftp.apnic.net/stats/apnic/delegated-apnic-latest 2>/dev/null \
        | grep '|CN|ipv4|' \
        | awk -F'|' '{ printf("%s/%d\n", $4, 32-log($5)/log(2)) }' > "$tmp" \
        && [ -s "$tmp" ] \
        && [ "$(wc -l < "$tmp")" -gt 100 ]; then

        mv "$tmp" "$CN_IP_CACHE"
        echo "已从 APNIC 官方源下载 $(wc -l < "$CN_IP_CACHE") 条 CIDR"
        return 0
    fi

    echo "APNIC 源失败，尝试备用源..."

    for url in \
        "https://raw.githubusercontent.com/fernvenue/chn-cidr-list/master/cidr.txt" \
        "https://raw.githubusercontent.com/metowolf/iplist/master/data/special/china.txt"; do

        if curl -sS --max-time 30 -o "$tmp" "$url" 2>/dev/null \
            && [ -s "$tmp" ] \
            && [ "$(wc -l < "$tmp")" -gt 100 ]; then

            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmp" > "$CN_IP_CACHE"

            if [ -s "$CN_IP_CACHE" ]; then
                echo "已从备用源下载 $(wc -l < "$CN_IP_CACHE") 条 CIDR"
                rm -f "$tmp"
                return 0
            fi
        fi
    done

    rm -f "$tmp"
    echo "警告: 所有源均失败，无法下载中国 IP 列表"
    return 1
}

start() {
    echo "启动 WARP 透明代理 (Google + China, 仅443)..."

    # redsocks 由 redsocks.service 管理。
    # 此处只检查，不直接运行 redsocks -c，也不 pkill。
    if ! systemctl is-active --quiet redsocks; then
        echo "redsocks 未运行，尝试通过 systemd 启动..."
        systemctl start redsocks || {
            echo "redsocks 启动失败"
            return 1
        }
    fi

    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE

    # 排除 Clash 测速地址
    for domain in www.gstatic.com connectivitycheck.gstatic.com; do
        for eip in $(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u); do
            [ -n "$eip" ] && iptables -t nat -A WARP_GOOGLE -d "$eip/32" -j RETURN
        done
    done

    for ip in $GOOGLE_IPS; do
        iptables -t nat -A WARP_GOOGLE -d "$ip" -p tcp --dport 443 \
            -j REDIRECT --to-ports 12345
    done

    ipset destroy cn_warp 2>/dev/null || true
    ipset create cn_warp hash:net hashsize 16384 maxelem 131072

    if [ ! -s "$CN_IP_CACHE" ] || [ "$(find "$CN_IP_CACHE" -mtime +7 2>/dev/null | wc -l)" -gt 0 ]; then
        download_cn_ips
    fi

    if [ -s "$CN_IP_CACHE" ]; then
        local count=0

        while IFS= read -r cidr; do
            [ -z "$cidr" ] && continue
            ipset add cn_warp "$cidr" 2>/dev/null && count=$((count+1))
        done < "$CN_IP_CACHE"

        echo "已加载 $count 条中国 IP 段到 ipset"

        iptables -t nat -A WARP_GOOGLE \
            -p tcp --dport 443 \
            -m set --match-set cn_warp dst \
            -j REDIRECT --to-ports 12345
    fi

    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null \
        || iptables -t nat -A OUTPUT -j WARP_GOOGLE

    echo "WARP 透明代理已启动 (Google + China, 仅443)"
}

stop() {
    echo "停止 WARP 透明代理规则..."

    # 不杀 redsocks。redsocks 生命周期交由 systemd 管理。
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
    ipset destroy cn_warp 2>/dev/null || true

    echo "WARP 透明代理规则已停止"
}

update() {
    echo "更新中国 IP 列表..."
    rm -f "$CN_IP_CACHE"
    download_cn_ips && echo "更新完成，请执行 warp restart 生效"
}

status() {
    echo "=== WARP 状态 ==="
    warp-cli status 2>/dev/null || echo "WARP 未运行"

    echo ""
    echo "=== Redsocks systemd 状态 ==="
    if systemctl is-active --quiet redsocks; then
        echo "运行中"
    else
        echo "未运行"
    fi

    echo ""
    echo "=== Redsocks 监听 ==="
    ss -lntp 2>/dev/null | grep ':12345' || echo "12345 未监听"

    echo ""
    echo "=== iptables 规则 ==="
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -5 || echo "无规则"

    echo ""
    echo "=== ipset cn_warp ==="
    CN_COUNT=$(ipset list cn_warp 2>/dev/null | grep -c "^[0-9]" || true)
    echo "中国 IP 段数量: ${CN_COUNT:-0}"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart)
        stop
        sleep 1
        start
        ;;
    status) status ;;
    update) update ;;
    *)
        echo "用法: $0 {start|stop|restart|status|update}"
        ;;
esac
SCRIPT

    chmod +x /usr/local/bin/warp-google

    cat > /etc/systemd/system/warp-google.service << 'EOF'
[Unit]
Description=WARP Google Transparent Proxy
Wants=network-online.target
Requires=redsocks.service
After=network-online.target warp-svc.service redsocks.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-google 2>/dev/null || true

    # 重新应用透明代理规则，systemd 只负责保持后续开机启动。
    /usr/local/bin/warp-google restart

    echo -e "${GREEN}✓ 透明代理配置完成${NC}"
}

test_connection() {
    echo -e "\n${CYAN}测试连接...${NC}"

    sleep 2

    GOOGLE_TEST=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$GOOGLE_TEST" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！${NC}"
    else
        echo -e "${YELLOW}Google 测试返回: $GOOGLE_TEST${NC}"
    fi

    BAIDU_TEST=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.baidu.com)
    if [ "$BAIDU_TEST" = "200" ]; then
        echo -e "${GREEN}✓ 百度连接成功 (via WARP)！${NC}"
    else
        echo -e "${YELLOW}百度测试返回: $BAIDU_TEST${NC}"
    fi

    WARP_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 10 ip.sb 2>/dev/null)

    if [ -n "$WARP_IP" ]; then
        WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
        echo -e "\nWARP IP: ${GREEN}$WARP_IP${NC}"
        echo -e "WARP 位置: ${GREEN}$(echo "$WARP_INFO" | grep -oP '"country":"\K[^"]+') - $(echo "$WARP_INFO" | grep -oP '"city":"\K[^"]+')${NC}"
    fi
}

create_management() {
    cat > /usr/local/bin/warp << 'EOF'
#!/bin/bash

case "$1" in
    status)
        warp-cli status 2>/dev/null
        echo ""
        /usr/local/bin/warp-google status 2>/dev/null
        ;;

    start)
        systemctl start warp-svc 2>/dev/null || true
        warp-cli connect 2>/dev/null || true
        sleep 2
        systemctl start redsocks
        systemctl start warp-google
        ;;

    stop)
        systemctl stop warp-google 2>/dev/null || true
        systemctl stop redsocks 2>/dev/null || true
        warp-cli disconnect 2>/dev/null || true
        ;;

    restart)
        systemctl stop warp-google 2>/dev/null || true
        systemctl stop redsocks 2>/dev/null || true
        warp-cli disconnect 2>/dev/null || true

        sleep 2

        systemctl restart warp-svc 2>/dev/null || true
        warp-cli connect 2>/dev/null || true

        sleep 2

        systemctl restart redsocks
        systemctl restart warp-google
        ;;

    update)
        /usr/local/bin/warp-google update
        ;;

    test)
        echo "测试 Google 连接..."
        curl -s --max-time 10 -o /dev/null -w "状态码: %{http_code}\n" https://www.google.com

        echo "测试百度连接 (via WARP)..."
        curl -s --max-time 10 -o /dev/null -w "状态码: %{http_code}\n" https://www.baidu.com
        ;;

    ip)
        echo "直连 IP:"
        curl -4 -s ip.sb
        echo ""

        echo "WARP IP:"
        curl -x socks5://127.0.0.1:40000 -s ip.sb
        echo ""
        ;;

    uninstall)
        echo "正在卸载..."

        systemctl stop warp-google 2>/dev/null || true
        systemctl disable warp-google 2>/dev/null || true
        systemctl stop redsocks 2>/dev/null || true
        systemctl disable redsocks 2>/dev/null || true
        warp-cli disconnect 2>/dev/null || true

        rm -f /etc/systemd/system/warp-google.service
        rm -f /usr/local/bin/warp-google
        rm -f /usr/local/bin/warp
        rm -f /etc/redsocks.conf
        rm -rf /etc/warp

        iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
        iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
        iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
        ipset destroy cn_warp 2>/dev/null || true

        systemctl daemon-reload

        apt-get remove -y cloudflare-warp redsocks 2>/dev/null \
            || yum remove -y cloudflare-warp redsocks 2>/dev/null \
            || true

        echo "WARP 已卸载"
        ;;

    *)
        echo "WARP 管理工具 (Google + China, 仅443)"
        echo ""
        echo "用法: warp <命令>"
        echo ""
        echo "命令:"
        echo "  status    查看状态"
        echo "  start     启动 WARP"
        echo "  stop      停止 WARP"
        echo "  restart   重启 WARP"
        echo "  update    更新中国 IP 列表"
        echo "  test      测试 Google + 百度"
        echo "  ip        查看 IP"
        echo "  uninstall 卸载 WARP"
        ;;
esac
EOF

    chmod +x /usr/local/bin/warp
}

do_install() {
    install_warp
    configure_warp
    setup_transparent_proxy
    create_management
    test_connection

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     🎉 安装完成！Google + 中国大陆已解锁 🎉         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"

    echo -e "\n${YELLOW}Google + 中国大陆 HTTPS 流量现已自动通过 WARP！${NC}"
    echo -e "${YELLOW}HTTP 80 端口保持直连 (不影响 Clash 测速)。${NC}"
    echo -e "\n管理命令: ${CYAN}warp {status|start|stop|restart|update|test|ip|uninstall}${NC}\n"
}

do_uninstall() {
    echo -e "\n${YELLOW}正在卸载 WARP...${NC}"

    systemctl stop warp-google 2>/dev/null || true
    systemctl disable warp-google 2>/dev/null || true
    systemctl stop redsocks 2>/dev/null || true
    systemctl disable redsocks 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true

    rm -f /etc/systemd/system/warp-google.service
    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp
    rm -f /etc/redsocks.conf

    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
    ipset destroy cn_warp 2>/dev/null || true

    ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null || true
    rm -rf /etc/warp

    case $OS in
        ubuntu|debian)
            apt-get remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum remove -y cloudflare-warp redsocks 2>/dev/null \
                || dnf remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac

    systemctl daemon-reload

    echo -e "${GREEN}✓ WARP 已完全卸载${NC}\n"
}

do_status() {
    echo -e "\n${CYAN}══════════════ WARP 运行状态 ══════════════${NC}\n"

    echo -e "${YELLOW}【WARP 客户端】${NC}"
    if command -v warp-cli &>/dev/null; then
        warp-cli status 2>/dev/null || echo "未运行"
    else
        echo -e "${RED}未安装${NC}"
    fi

    echo ""
    echo -e "${YELLOW}【Redsocks systemd】${NC}"
    if systemctl is-active --quiet redsocks; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi

    echo ""
    echo -e "${YELLOW}【Redsocks 监听端口】${NC}"
    ss -lntp 2>/dev/null | grep ':12345' || echo -e "${RED}12345 未监听${NC}"

    echo ""
    echo -e "${YELLOW}【透明代理服务】${NC}"
    if systemctl is-active --quiet warp-google; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi

    echo ""
    echo -e "${YELLOW}【iptables 规则】${NC}"
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -3 || echo -e "${RED}无规则${NC}"

    echo -e "\n${CYAN}════════════════════════════════════════════${NC}\n"
}

do_show_ip() {
    echo -e "\n${CYAN}══════════════ IP 信息 ══════════════${NC}\n"

    echo -e "${YELLOW}【直连 IP】${NC}"
    DIRECT_IP=$(curl -4 -s --max-time 5 ip.sb)
    DIRECT_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$DIRECT_IP?lang=zh-CN" 2>/dev/null)
    echo -e "IP: ${GREEN}$DIRECT_IP${NC}"
    echo -e "位置: $(echo "$DIRECT_INFO" | grep -oP '"country":"\K[^"]+') - $(echo "$DIRECT_INFO" | grep -oP '"city":"\K[^"]+')\n"

    echo -e "${YELLOW}【WARP IP】${NC}"
    WARP_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 5 ip.sb 2>/dev/null)

    if [ -n "$WARP_IP" ]; then
        WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
        echo -e "IP: ${GREEN}$WARP_IP${NC}"
        echo -e "位置: $(echo "$WARP_INFO" | grep -oP '"country":"\K[^"]+') - $(echo "$WARP_INFO" | grep -oP '"city":"\K[^"]+')\n"
    else
        echo -e "${RED}无法获取 (WARP 可能未运行)${NC}\n"
    fi

    echo -e "${CYAN}══════════════════════════════════════${NC}\n"
}

do_test_google() {
    echo -e "\n${CYAN}测试连接...${NC}"

    RESULT=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)

    if [ "$RESULT" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！状态码: $RESULT${NC}"
    else
        echo -e "${RED}✗ Google 连接失败，状态码: $RESULT${NC}"
    fi

    RESULT2=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.baidu.com)

    if [ "$RESULT2" = "200" ]; then
        echo -e "${GREEN}✓ 百度连接成功 (via WARP)！状态码: $RESULT2${NC}\n"
    else
        echo -e "${RED}✗ 百度连接失败，状态码: $RESULT2${NC}\n"
    fi
}

show_menu() {
    echo -e "${YELLOW}请选择操作:${NC}\n"
    echo -e "  ${GREEN}1.${NC} 安装/修复 WARP (解锁 Google/Gemini + 中国大陆)"
    echo -e "  ${GREEN}2.${NC} 卸载 WARP"
    echo -e "  ${GREEN}3.${NC} 查看状态"
    echo -e "  ${GREEN}0.${NC} 退出\n"

    read -p "请输入选项 [0-3]: " choice

    case $choice in
        1) do_install ;;
        2) do_uninstall ;;
        3)
            do_status
            do_show_ip
            do_test_google
            ;;
        0)
            echo -e "\n${GREEN}再见！${NC}\n"
            exit 0
            ;;
        *)
            echo -e "\n${RED}无效选项${NC}\n"
            ;;
    esac
}

main() {
    show_banner

    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        CODENAME=$VERSION_CODENAME
    else
        echo -e "${RED}无法检测系统${NC}"
        exit 1
    fi

    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

    echo -e "${GREEN}系统: $OS $VERSION ($CODENAME) $ARCH${NC}\n"

    echo -e "${YELLOW}当前 IP 信息:${NC}"
    CURRENT_IP=$(curl -4 -s --max-time 5 ip.sb)
    IP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$CURRENT_IP?lang=zh-CN" 2>/dev/null)

    echo -e "IP: ${GREEN}$CURRENT_IP${NC}"
    echo -e "位置: ${GREEN}$(echo "$IP_INFO" | grep -oP '"country":"\K[^"]+') - $(echo "$IP_INFO" | grep -oP '"city":"\K[^"]+')${NC}\n"

    if [ -n "$1" ]; then
        case "$1" in
            1)
                echo -e "\n${YELLOW}检测到自动运行参数，开始安装/修复 (解锁 Google/Gemini + 中国大陆)...${NC}"
                do_install
                exit 0
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                exit 1
                ;;
        esac
    else
        show_menu
    fi
}

main "$@"
