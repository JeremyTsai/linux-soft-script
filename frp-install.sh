#!/bin/bash

#==================================================
# FRP 一键安装/升级脚本 v3.0
# 特性：非登录用户运行、动态防火墙配置、配置备份
#==================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置变量
FRP_DIR="/usr/local/frp"
FRP_BIN_DIR="/usr/local/bin"
FRP_USER="frp"
FRP_VERSION_FILE="${FRP_DIR}/.version"
GITHUB_API="https://api.github.com/repos/fatedier/frp/releases/latest"

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：此脚本需要 root 权限运行${NC}"
        exit 1
    fi
}

# 获取系统架构
get_arch() {
    local arch=$(uname -m)
    case ${arch} in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "arm" ;;
        i386|i686) echo "386" ;;
        *)
            echo -e "${RED}不支持的架构: ${arch}${NC}"
            exit 1
            ;;
    esac
}

# 检测是否已安装
check_installed() {
    [[ -d "${FRP_DIR}" ]] && return 0 || return 1
}

# 获取已安装版本
get_installed_version() {
    if [[ -f "${FRP_VERSION_FILE}" ]]; then
        cat "${FRP_VERSION_FILE}"
    else
        echo "unknown"
    fi
}

# 获取最新版本
get_latest_version() {
    echo -e "${BLUE}正在获取最新版本信息...${NC}"
    local version=$(curl -s --connect-timeout 10 ${GITHUB_API} | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "${version}" ]]; then
        echo -e "${RED}获取最新版本失败${NC}"
        exit 1
    fi
    echo "${version}"
}

#==================================================
# 用户管理模块（健壮性检查 + 最小权限）
#==================================================

# 检查并创建 frp 专用用户（非登录）
setup_frp_user() {
    echo -e "\n${BLUE}=== 用户权限配置 ===${NC}"
    
    # 检查用户是否已存在（健壮性检查）
    if id -u "${FRP_USER}" &>/dev/null; then
        echo -e "${YELLOW}用户 ${FRP_USER} 已存在，跳过创建${NC}"
        # 确保用户shell为nologin（安全检查）
        local current_shell=$(grep "^${FRP_USER}:" /etc/passwd | cut -d: -f7)
        if [[ "${current_shell}" != "/sbin/nologin" && "${current_shell}" != "/bin/false" ]]; then
            echo -e "${YELLOW}警告：用户 ${FRP_USER} 当前 shell 为 ${current_shell}，建议改为 /sbin/nologin${NC}"
            read -p "是否修正为 /sbin/nologin？[Y/n]: " fix_shell
            if [[ ! "${fix_shell}" =~ ^[Nn]$ ]]; then
                usermod -s /sbin/nologin "${FRP_USER}" 2>/dev/null || usermod -s /bin/false "${FRP_USER}"
                echo -e "${GREEN}已修正 shell 为 nologin${NC}"
            fi
        fi
    else
        echo -e "${BLUE}创建专用用户 ${FRP_USER}（非登录、最小权限）...${NC}"
        # 创建系统用户：-r（系统用户），-s（指定shell），-M（不创建home目录）
        if useradd -r -s /sbin/nologin -M "${FRP_USER}" 2>/dev/null; then
            echo -e "${GREEN}✓ 用户 ${FRP_USER} 创建成功${NC}"
        else
            # 备选方案（某些系统可能不支持 -r 或 -M）
            if useradd -s /bin/false "${FRP_USER}"; then
                echo -e "${GREEN}✓ 用户 ${FRP_USER} 创建成功（使用备选参数）${NC}"
            else
                echo -e "${RED}✗ 用户创建失败${NC}"
                exit 1
            fi
        fi
    fi
    
    # 检查用户组
    if ! getent group "${FRP_USER}" &>/dev/null; then
        groupadd -r "${FRP_USER}" 2>/dev/null || true
    fi
    
    # 设置目录权限（最小权限原则）
    echo -e "${BLUE}配置目录权限...${NC}"
    
    # 创建目录并设置所有权
    mkdir -p "${FRP_DIR}"
    chown -R "${FRP_USER}:${FRP_USER}" "${FRP_DIR}"
    
    # 设置权限：所有者读写执行，组和其他人无写权限
    chmod 755 "${FRP_DIR}"
    
    # 二进制文件允许用户执行，但归 root 所有（安全考虑）
    if [[ -f "${FRP_DIR}/frps" ]]; then
        chmod 755 "${FRP_DIR}/frps"
        chmod 755 "${FRP_DIR}/frpc"
        # 二进制保持root所有，但frp用户可以读取执行
        chown root:root "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
    fi
    
    # 日志目录允许 frp 用户写入
    mkdir -p "${FRP_DIR}/logs"
    chown "${FRP_USER}:${FRP_USER}" "${FRP_DIR}/logs"
    chmod 750 "${FRP_DIR}/logs"
    
    echo -e "${GREEN}✓ 权限配置完成${NC}"
    echo -e "  用户: ${CYAN}${FRP_USER}${NC} (UID: $(id -u ${FRP_USER}))"
    echo -e "  目录: ${CYAN}${FRP_DIR}${NC} (所有权: ${FRP_USER}:${FRP_USER})"
    
    # 如果需要绑定特权端口（<1024），提示使用 setcap 或 authbind
    check_privileged_ports
}

# 检查是否需要特权端口授权
check_privileged_ports() {
    local config_file="${FRP_DIR}/frps.toml"
    if [[ -f "${config_file}" ]]; then
        # 检查是否配置了低端口
        local http_port=$(grep -E "^vhostHTTPPort\s*=" "${config_file}" | grep -o '[0-9]*' | head -1)
        local https_port=$(grep -E "^vhostHTTPSPort\s*=" "${config_file}" | grep -o '[0-9]*' | head -1)
        
        if [[ -n "${http_port}" && "${http_port}" -lt 1024 ]] || [[ -n "${https_port}" && "${https_port}" -lt 1024 ]]; then
            echo -e "\n${YELLOW}注意：检测到配置了特权端口（<1024）${NC}"
            echo -e "${BLUE}正在为 ${FRP_USER} 授权绑定特权端口...${NC}"
            
            # 方法1：使用 setcap（推荐）
            if command -v setcap &>/dev/null; then
                setcap 'cap_net_bind_service=+ep' "${FRP_DIR}/frps" 2>/dev/null || true
                setcap 'cap_net_bind_service=+ep' "${FRP_BIN_DIR}/frps" 2>/dev/null || true
                echo -e "${GREEN}✓ 已使用 setcap 授权绑定特权端口${NC}"
            else
                echo -e "${YELLOW}！未找到 setcap，如需绑定 80/443 端口，请手动安装 libcap2-bin${NC}"
                echo -e "  或考虑使用反向代理（Nginx）转发到非特权端口${NC}"
            fi
        fi
    fi
}

#==================================================
# 动态防火墙配置模块（交互式）
#==================================================

# 从 frps.toml 解析端口配置
parse_frp_ports() {
    local config_file="${FRP_DIR}/frps.toml"
    local ports=()
    
    if [[ ! -f "${config_file}" ]]; then
        echo ""
        return
    fi
    
    # 使用 grep 和 sed 提取端口号（处理 TOML 格式）
    # bindPort（核心端口，必需）
    local bind_port=$(grep -E "^bindPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${bind_port}" ]] && ports+=("${bind_port}/tcp")
    
    # webServer.port（管理界面）
    local web_port=$(grep -E "^webServer\.port\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${web_port}" ]] && ports+=("${web_port}/tcp")
    
    # vhostHTTPPort（HTTP 代理）
    local http_port=$(grep -E "^vhostHTTPPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${http_port}" ]] && ports+=("${http_port}/tcp")
    
    # vhostHTTPSPort（HTTPS 代理）
    local https_port=$(grep -E "^vhostHTTPSPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${https_port}" ]] && ports+=("${https_port}/tcp")
    
    # 提取 allowPorts 范围（较复杂的解析）
    # 简单处理：查找单端口或范围
    while IFS= read -r line; do
        # 匹配 single = port
        if [[ "${line}" =~ single\ *=\ *([0-9]+) ]]; then
            ports+=("${BASH_REMATCH[1]}/tcp")
        fi
        # 匹配范围 { start = x, end = y }
        if [[ "${line}" =~ start\ *=\ *([0-9]+) ]]; then
            local start_port="${BASH_REMATCH[1]}"
            if [[ "${line}" =~ end\ *=\ *([0-9]+) ]]; then
                local end_port="${BASH_REMATCH[1]}"
                ports+=("${start_port}-${end_port}/tcp")
            fi
        fi
    done < <(grep -A 5 "allowPorts" "${config_file}" 2>/dev/null || true)
    
    # 去重并输出
    printf "%s\n" "${ports[@]}" | sort -u | tr '\n' ' '
}

# 交互式防火墙配置
setup_firewall_interactive() {
    local ports_str=$(parse_frp_ports)
    
    echo -e "\n${BLUE}=== 防火墙配置 ===${NC}"
    
    if [[ -z "${ports_str}" ]]; then
        echo -e "${YELLOW}未在 frps.toml 中检测到端口配置，跳过防火墙设置${NC}"
        return 0
    fi
    
    # 显示检测到的端口
    echo -e "${CYAN}根据 ${FRP_DIR}/frps.toml 检测到以下端口需要开放：${NC}"
    for port in ${ports_str}; do
        echo -e "  • ${YELLOW}${port}${NC}"
    done
    
    # 交互式询问
    echo ""
    read -p "是否配置防火墙开放以上端口？ [Y/n/skip(跳过)]: " fw_choice
    
    case "${fw_choice}" in
        [Nn])
            echo -e "${YELLOW}已跳过防火墙配置${NC}"
            return 0
            ;;
        [Ss]*)
            echo -e "${YELLOW}已跳过防火墙配置${NC}"
            return 0
            ;;
        *)
            # 执行防火墙配置
            configure_firewall "${ports_str}"
            ;;
    esac
}

# 配置防火墙（根据检测到的类型）
configure_firewall() {
    local ports="$1"
    
    # 检测可用的防火墙工具（优先级：firewalld > ufw > iptables）
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo -e "${BLUE}检测到 Firewalld，正在配置...${NC}"
        for port in ${ports}; do
            local port_num=${port%/*}
            local proto=${port#*/}
            echo -e "  开放端口: ${port_num}/${proto}"
            firewall-cmd --permanent --add-port="${port_num}/${proto}" 2>/dev/null || true
        done
        firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}✓ Firewalld 配置完成${NC}"
        
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${BLUE}检测到 UFW，正在配置...${NC}"
        for port in ${ports}; do
            local port_num=${port%/*}
            local proto=${port#*/}
            echo -e "  开放端口: ${port_num}/${proto}"
            # ufw 支持范围格式：6000:7000/tcp
            ufw allow "${port}" comment 'FRP Service' 2>/dev/null || true
        done
        echo -e "${GREEN}✓ UFW 配置完成${NC}"
        
    elif command -v iptables &>/dev/null; then
        echo -e "${BLUE}检测到 iptables，正在配置...${NC}"
        echo -e "${YELLOW}注意：iptables 规则重启后会失效，建议安装 firewalld 或 ufw${NC}"
        for port in ${ports}; do
            local port_num=${port%/*}
            local proto=${port#*/}
            echo -e "  开放端口: ${port_num}/${proto}"
            iptables -I INPUT -p "${proto}" --dport "${port_num}" -j ACCEPT 2>/dev/null || true
        done
        # 尝试保存（不同发行版命令不同）
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
        elif command -v service &>/dev/null && service iptables save 2>/dev/null; then
            service iptables save 2>/dev/null || true
        elif [[ -f /etc/sysconfig/iptables ]]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        echo -e "${GREEN}✓ iptables 配置完成${NC}"
        
    else
        echo -e "${YELLOW}! 未检测到活动的防火墙工具（firewalld/ufw/iptables）${NC}"
        echo -e "请手动开放以下端口："
        for port in ${ports}; do
            echo -e "  ${YELLOW}${port}${NC}"
        done
    fi
}

#==================================================
# 安装/升级功能
#==================================================

download_frp() {
    local version=$1
    local arch=$(get_arch)
    local download_url="https://github.com/fatedier/frp/releases/download/${version}/frp_${version:1}_linux_${arch}.tar.gz"
    local temp_dir=$(mktemp -d)
    
    echo -e "${BLUE}正在下载 frp ${version} (${arch})...${NC}"
    cd "${temp_dir}"
    
    if ! curl -L --progress-bar -o frp.tar.gz "${download_url}"; then
        echo -e "${RED}下载失败！${NC}"
        rm -rf "${temp_dir}"
        exit 1
    fi
    
    echo -e "${GREEN}下载完成，正在解压...${NC}"
    tar -xzf frp.tar.gz
    rm -f frp.tar.gz
    
    ls -d frp_* 2>/dev/null || echo ""
}

backup_config() {
    if [[ -d "${FRP_DIR}" ]]; then
        local backup_dir="${FRP_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}备份现有配置到: ${backup_dir}${NC}"
        cp -r "${FRP_DIR}" "${backup_dir}"
        echo "${backup_dir}"
    fi
}

restore_config() {
    local backup_dir=$1
    if [[ -d "${backup_dir}" ]]; then
        echo -e "${BLUE}恢复配置文件...${NC}"
        for file in frps.toml frpc.toml frps.ini frpc.ini; do
            if [[ -f "${backup_dir}/${file}" ]]; then
                cp "${backup_dir}/${file}" "${FRP_DIR}/" 2>/dev/null || true
                echo -e "  恢复: ${file}"
            fi
        done
        # 恢复后确保权限正确
        chown -R "${FRP_USER}:${FRP_USER}" "${FRP_DIR}"/*.toml 2>/dev/null || true
    fi
}

create_default_config() {
    local random_token=$(openssl rand -base64 16 2>/dev/null || tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    
    # 服务端配置（包含所有常用选项作为注释）
    cat > "${FRP_DIR}/frps.toml" << EOF
# FRP 服务端配置
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')

# 核心通信端口（客户端连接用）
bindPort = 7000
bindAddr = "0.0.0.0"

# 身份验证（重要！必须设置）
auth.method = "token"
auth.token = "${random_token}"

# Web 管理界面
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "$(openssl rand -base64 12 2>/dev/null || echo 'admin123')"

# 多路复用（提升性能）
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30

# 心跳配置
heartbeatTimeout = 90

# 日志配置
log.to = "./logs/frps.log"
log.level = "info"
log.maxDays = 30

# 额外端口配置（取消注释以启用）
# vhostHTTPPort = 80    # HTTP 代理端口（需防火墙开放）
# vhostHTTPSPort = 443  # HTTPS 代理端口（需防火墙开放）

# 端口白名单（可选，限制客户端可绑定的端口）
# allowPorts = [
#   { start = 6000, end = 7000 },
#   { single = 3389 }
# ]

# 传输层安全配置（生产环境建议开启）
# transport.tls.force = true
EOF

    # 设置配置文件权限（frp用户可读写，其他人只读）
    chown "${FRP_USER}:${FRP_USER}" "${FRP_DIR}/frps.toml"
    chmod 640 "${FRP_DIR}/frps.toml"

    # 客户端配置
    cat > "${FRP_DIR}/frpc.toml" << EOF
# FRP 客户端配置
# 请修改 serverAddr 为你的服务器 IP

serverAddr = "YOUR_SERVER_IP"
serverPort = 7000

# 身份验证（必须与服务端一致）
auth.method = "token"
auth.token = "${random_token}"

# Web 管理界面（本地）
webServer.addr = "127.0.0.1"
webServer.port = 7400

# 日志配置
log.to = "./logs/frpc.log"
log.level = "info"
log.maxDays = 30

# 传输配置
transport.poolCount = 5
transport.tcpMux = true
transport.protocol = "tcp"

# 代理配置示例：SSH
[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
transport.useEncryption = true
transport.useCompression = true

# 代理配置示例：HTTP 服务（需服务端开启 vhostHTTPPort）
# [[proxies]]
# name = "web"
# type = "http"
# localIP = "127.0.0.1"
# localPort = 8080
# customDomains = ["your.domain.com"]
EOF

    chown "${FRP_USER}:${FRP_USER}" "${FRP_DIR}/frpc.toml"
    chmod 640 "${FRP_DIR}/frpc.toml"
    
    echo -e "${GREEN}配置文件已生成:${NC}"
    echo -e "  服务端: ${YELLOW}${FRP_DIR}/frps.toml${NC}"
    echo -e "  客户端: ${YELLOW}${FRP_DIR}/frpc.toml${NC}"
    echo -e "  默认 Token: ${CYAN}${random_token}${NC}"
}

install_systemd_services() {
    # 创建二进制文件软链接
    ln -sf "${FRP_DIR}/frps" "${FRP_BIN_DIR}/frps"
    ln -sf "${FRP_DIR}/frpc" "${FRP_BIN_DIR}/frpc"
    
    # 服务端服务（使用非root用户运行）
    cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=FRP Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${FRP_USER}
Group=${FRP_USER}
Restart=on-failure
RestartSec=5s
WorkingDirectory=${FRP_DIR}
ExecStart=${FRP_BIN_DIR}/frps -c ${FRP_DIR}/frps.toml
LimitNOFILE=1048576
StandardOutput=append:${FRP_DIR}/logs/frps-systemd.log
StandardError=append:${FRP_DIR}/logs/frps-systemd.log

# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${FRP_DIR}/logs

[Install]
WantedBy=multi-user.target
EOF

    # 客户端服务
    cat > /etc/systemd/system/frpc.service << EOF
[Unit]
Description=FRP Client Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${FRP_USER}
Group=${FRP_USER}
Restart=on-failure
RestartSec=5s
WorkingDirectory=${FRP_DIR}
ExecStart=${FRP_BIN_DIR}/frpc -c ${FRP_DIR}/frpc.toml
LimitNOFILE=1048576
StandardOutput=append:${FRP_DIR}/logs/frpc-systemd.log
StandardError=append:${FRP_DIR}/logs/frpc-systemd.log

# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${FRP_DIR}/logs

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}Systemd 服务已安装（运行用户: ${FRP_USER}）${NC}"
}

# 主安装流程
install_frp() {
    local is_upgrade=$1
    
    if [[ "${is_upgrade}" == "true" ]]; then
        echo -e "${YELLOW}开始升级 FRP...${NC}"
        systemctl stop frps 2>/dev/null || true
        systemctl stop frpc 2>/dev/null || true
        local backup_dir=$(backup_config)
    else
        echo -e "${GREEN}开始安装 FRP...${NC}"
        mkdir -p "${FRP_DIR}" "${FRP_BIN_DIR}"
    fi
    
    local latest_version=$(get_latest_version)
    echo -e "目标版本: ${GREEN}${latest_version}${NC}"
    
    # 版本检查
    if [[ "${is_upgrade}" == "true" ]]; then
        local current_version=$(get_installed_version)
        if [[ "${current_version}" == "${latest_version}" ]]; then
            echo -e "${YELLOW}当前已是最新版本 ${current_version}${NC}"
            read -p "是否强制重新安装？[y/N]: " force_install
            if [[ ! "${force_install}" =~ ^[Yy]$ ]]; then
                systemctl start frps 2>/dev/null || true
                return 0
            fi
        fi
    fi
    
    # 下载解压
    local temp_extract_dir=$(download_frp "${latest_version}")
    cd /
    
    if [[ "${is_upgrade}" == "true" ]]; then
        # 升级：只替换二进制文件
        cp "${temp_extract_dir}/frps" "${FRP_DIR}/"
        cp "${temp_extract_dir}/frpc" "${FRP_DIR}/"
        chmod 755 "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
        restore_config "${backup_dir}"
    else
        # 全新安装
        rm -rf "${FRP_DIR}"/*
        mv "${temp_extract_dir}"/* "${FRP_DIR}/"
        chmod 755 "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
        create_default_config
    fi
    
    rm -rf "$(dirname ${temp_extract_dir})/${temp_extract_dir}" 2>/dev/null || true
    
    # 设置用户权限（关键步骤）
    setup_frp_user
    
    # 安装服务（非root运行）
    install_systemd_services
    
    # 记录版本
    echo "${latest_version}" > "${FRP_VERSION_FILE}"
    chown "${FRP_USER}:${FRP_USER}" "${FRP_VERSION_FILE}"
    
    echo -e "\n${GREEN}安装/升级完成！${NC}"
    
    # 交互式防火墙配置（非静默）
    if [[ "${is_upgrade}" != "true" ]] || [[ -n "${backup_dir}" ]]; then
        setup_firewall_interactive
    fi
    
    # 显示后续步骤
    echo -e "\n${YELLOW}=== 后续步骤 ===${NC}"
    if [[ "${is_upgrade}" != "true" ]]; then
        echo -e "1. 编辑服务端配置: ${BLUE}nano ${FRP_DIR}/frps.toml${NC}"
        echo -e "   （建议修改默认 Token 和管理界面密码）"
        echo -e "2. 启动服务端: ${BLUE}systemctl start frps${NC}"
        echo -e "3. 查看状态: ${BLUE}systemctl status frps${NC}"
        echo -e "4. 设置开机自启: ${BLUE}systemctl enable frps${NC}"
        echo -e "\n客户端操作:"
        echo -e "1. 编辑配置: ${BLUE}nano ${FRP_DIR}/frpc.toml${NC}（修改 serverAddr）"
        echo -e "2. 启动: ${BLUE}systemctl start frpc${NC}"
    else
        echo -e "服务已自动重启（配置已保留）"
        systemctl restart frps 2>/dev/null || echo -e "${YELLOW}frps 服务启动失败${NC}"
        systemctl restart frpc 2>/dev/null || true
    fi
}

# 卸载
uninstall_frp() {
    echo -e "${RED}正在卸载 FRP...${NC}"
    
    # 停止并禁用服务
    systemctl stop frps 2>/dev/null || true
    systemctl stop frpc 2>/dev/null || true
    systemctl disable frps 2>/dev/null || true
    systemctl disable frpc 2>/dev/null || true
    
    rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
    systemctl daemon-reload
    
    rm -f "${FRP_BIN_DIR}/frps" "${FRP_BIN_DIR}/frpc"
    
    # 备份并删除目录
    if [[ -d "${FRP_DIR}" ]]; then
        local backup_dir="${FRP_DIR}.backup.uninstall.$(date +%Y%m%d_%H%M%S)"
        mv "${FRP_DIR}" "${backup_dir}"
        echo -e "${YELLOW}配置已备份至: ${backup_dir}${NC}"
    fi
    
    # 询问是否删除用户
    read -p "是否删除专用用户 ${FRP_USER}？[y/N]: " del_user
    if [[ "${del_user}" =~ ^[Yy]$ ]]; then
        userdel "${FRP_USER}" 2>/dev/null && echo -e "${GREEN}用户已删除${NC}" || echo -e "${YELLOW}用户删除失败或不存在${NC}"
    fi
    
    echo -e "${GREEN}FRP 已卸载完成${NC}"
}

# 状态显示
show_status() {
    echo -e "\n${BLUE}=== FRP 状态 ===${NC}"
    
    if check_installed; then
        local version=$(get_installed_version)
        echo -e "安装状态: ${GREEN}已安装${NC} (${version})"
        echo -e "安装目录: ${FRP_DIR}"
        
        # 检查用户
        if id -u "${FRP_USER}" &>/dev/null; then
            echo -e "运行用户: ${GREEN}${FRP_USER}${NC} (shell: $(grep "^${FRP_USER}:" /etc/passwd | cut -d: -f7))"
        else
            echo -e "运行用户: ${RED}不存在${NC}"
        fi
        
        # 服务状态
        echo -e "\n${CYAN}服务状态:${NC}"
        for svc in frps frpc; do
            if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
                local status=$(systemctl is-active ${svc} 2>/dev/null || echo "not installed")
                if [[ "${status}" == "active" ]]; then
                    echo -e "  ${svc}: ${GREEN}运行中${NC}"
                else
                    echo -e "  ${svc}: ${RED}${status}${NC}"
                fi
            fi
        done
        
        # 检测到的端口
        local ports=$(parse_frp_ports)
        if [[ -n "${ports}" ]]; then
            echo -e "\n${CYAN}配置端口:${NC} ${ports}"
        fi
    else
        echo -e "安装状态: ${RED}未安装${NC}"
    fi
}

# 交互式菜单
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}     FRP 安装管理脚本 v3.0${NC}"
        echo -e "${GREEN}========================================${NC}"
        
        local install_status="${RED}未安装${NC}"
        local version_info=""
        if check_installed; then
            install_status="${GREEN}已安装${NC}"
            version_info="($(get_installed_version))"
        fi
        echo -e "当前状态: ${install_status} ${version_info}"
        echo ""
        
        echo "1. 安装 FRP（创建专用用户+交互式防火墙）"
        echo "2. 升级 FRP（保留配置）"
        echo "3. 卸载 FRP"
        echo "4. 查看状态"
        echo "5. 服务管理（启动/停止/重启）"
        echo "6. 配置防火墙（基于当前 frps.toml）"
        echo "7. 编辑服务端配置"
        echo "8. 编辑客户端配置"
        echo "0. 退出"
        echo ""
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1)
                if check_installed; then
                    read -p "FRP 已安装，是否重新安装？将备份配置 [y/N]: " confirm
                    [[ "${confirm}" =~ ^[Yy]$ ]] && install_frp "false"
                else
                    install_frp "false"
                fi
                read -p "按回车继续..."
                ;;
            2)
                if check_installed; then
                    install_frp "true"
                else
                    echo -e "${RED}未安装，无法升级${NC}"
                fi
                read -p "按回车继续..."
                ;;
            3)
                if check_installed; then
                    read -p "确定卸载？配置将备份 [y/N]: " confirm
                    [[ "${confirm}" =~ ^[Yy]$ ]] && uninstall_frp
                fi
                read -p "按回车继续..."
                ;;
            4)
                show_status
                read -p "按回车继续..."
                ;;
            5)
                service_management_menu
                ;;
            6)
                setup_firewall_interactive
                read -p "按回车继续..."
                ;;
            7)
                [[ -f "${FRP_DIR}/frps.toml" ]] && nano "${FRP_DIR}/frps.toml" || echo "文件不存在"
                read -p "按回车继续..."
                ;;
            8)
                [[ -f "${FRP_DIR}/frpc.toml" ]] && nano "${FRP_DIR}/frpc.toml" || echo "文件不存在"
                read -p "按回车继续..."
                ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

service_management_menu() {
    while true; do
        echo -e "\n${CYAN}=== 服务管理 ===${NC}"
        echo "1. 启动 frps  2. 停止 frps  3. 重启 frps  4. 状态 frps"
        echo "5. 启动 frpc  6. 停止 frpc  7. 重启 frpc  8. 状态 frpc"
        echo "9. 查看 frps 日志  10. 查看 frpc日志  0. 返回"
        read -p "选择: " n
        case $n in
            1) systemctl start frps && echo "已启动" || echo "失败" ;;
            2) systemctl stop frps && echo "已停止" ;;
            3) systemctl restart frps && echo "已重启" ;;
            4) systemctl status frps --no-pager ;;
            5) systemctl start frpc && echo "已启动" || echo "失败" ;;
            6) systemctl stop frpc && echo "已停止" ;;
            7) systemctl restart frpc && echo "已重启" ;;
            8) systemctl status frpc --no-pager ;;
            9) journalctl -u frps -n 50 --no-pager ;;
            10) journalctl -u frpc -n 50 --no-pager ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

# 入口
check_root
show_menu
