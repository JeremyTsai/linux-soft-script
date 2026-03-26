#!/bin/bash

#==================================================
# FRP 一键安装/升级脚本 v3.2 (修复检测和错误处理)
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
        echo -e "${RED}错误：此脚本需要 root 权限运行${NC}" >&2
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
            echo -e "${RED}不支持的架构: ${arch}${NC}" >&2
            exit 1
            ;;
    esac
}

# 检测是否已安装（修复：检查二进制文件而非仅目录）
check_installed() {
    # 检查关键文件是否存在且可执行，避免空目录误判
    if [[ -x "${FRP_DIR}/frps" ]] && [[ -x "${FRP_DIR}/frpc" ]]; then
        return 0
    else
        # 如果目录存在但二进制不存在，可能是之前安装失败的残留，清理掉
        if [[ -d "${FRP_DIR}" ]] && [[ ! -f "${FRP_DIR}/frps" ]]; then
            echo -e "${YELLOW}检测到残留空目录，正在清理...${NC}" >&2
            rm -rf "${FRP_DIR}"
        fi
        return 1
    fi
}

# 获取已安装版本
get_installed_version() {
    if [[ -f "${FRP_VERSION_FILE}" ]]; then
        cat "${FRP_VERSION_FILE}"
    else
        echo "unknown"
    fi
}

# 获取最新版本（修复：增加重试和空值检查）
get_latest_version() {
    echo -e "${BLUE}正在获取最新版本信息...${NC}" >&2
    
    local version=""
    local retry_count=0
    local max_retries=3
    
    while [[ -z "${version}" && ${retry_count} -lt ${max_retries} ]]; do
        # 使用 -m 10 限制最大时间，避免卡死
        version=$(curl -sL --max-time 10 --retry 3 --retry-delay 2 ${GITHUB_API} | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | tr -d '\n\r ')
        
        if [[ -z "${version}" ]]; then
            ((retry_count++))
            if [[ ${retry_count} -lt ${max_retries} ]]; then
                echo -e "${YELLOW}获取失败，${retry_count}秒后重试...${NC}" >&2
                sleep ${retry_count}
            fi
        fi
    done
    
    if [[ -z "${version}" ]]; then
        echo -e "${RED}错误：无法连接到 GitHub API 获取最新版本${NC}" >&2
        echo -e "${YELLOW}请检查网络连接，或手动指定版本安装${NC}" >&2
        # 返回空字符串，让调用方处理
        echo ""
        return 1
    fi
    
    printf '%s' "${version}"
}

# 下载 frp（修复：增加版本号空值检查）
download_frp() {
    local version=$1
    local arch=$(get_arch)
    
    # 关键检查：如果版本号为空，直接退出
    if [[ -z "${version}" ]]; then
        echo -e "${RED}错误：版本号为空，无法下载${NC}" >&2
        exit 1
    fi
    
    # 确保版本号格式正确（去掉可能的v前缀用于URL）
    local version_clean=${version#v}
    local download_url="https://github.com/fatedier/frp/releases/download/${version}/frp_${version_clean}_linux_${arch}.tar.gz"
    local temp_dir=$(mktemp -d)
    
    echo -e "${BLUE}正在下载 frp ${version} (${arch})...${NC}"
    echo -e "${YELLOW}下载地址: ${download_url}${NC}"
    
    cd "${temp_dir}"
    
    # 下载，带重试
    if ! curl -fL --max-time 60 --retry 3 --retry-delay 2 --progress-bar -o frp.tar.gz "${download_url}"; then
        echo -e "${RED}下载失败！请检查版本号是否正确: ${version}${NC}" >&2
        rm -rf "${temp_dir}"
        exit 1
    fi
    
    echo -e "${GREEN}下载完成，正在解压...${NC}"
    tar -xzf frp.tar.gz
    rm -f frp.tar.gz
    
    # 查找解压后的目录
    local extract_dir=$(find . -maxdepth 1 -type d -name "frp_*" | head -1 | sed 's|^\./||')
    
    if [[ -z "${extract_dir}" ]]; then
        echo -e "${RED}解压后未找到 frp 目录${NC}" >&2
        rm -rf "${temp_dir}"
        exit 1
    fi
    
    # 检查关键文件是否存在
    if [[ ! -f "${temp_dir}/${extract_dir}/frps" ]] || [[ ! -f "${temp_dir}/${extract_dir}/frpc" ]]; then
        echo -e "${RED}错误：下载的文件不完整，缺少 frps 或 frpc${NC}" >&2
        rm -rf "${temp_dir}"
        exit 1
    fi
    
    echo "${temp_dir}/${extract_dir}"
}

#==================================================
# 用户管理模块
#==================================================

setup_frp_user() {
    echo -e "\n${BLUE}=== 用户权限配置 ===${NC}"
    
    if id -u "${FRP_USER}" &>/dev/null; then
        echo -e "${YELLOW}用户 ${FRP_USER} 已存在，跳过创建${NC}"
        local current_shell=$(grep "^${FRP_USER}:" /etc/passwd | cut -d: -f7)
        if [[ "${current_shell}" != "/sbin/nologin" && "${current_shell}" != "/bin/false" ]]; then
            echo -e "${YELLOW}警告：用户 ${FRP_USER} 当前 shell 为 ${current_shell}${NC}"
            read -p "是否修正为 /sbin/nologin？[Y/n]: " fix_shell
            if [[ ! "${fix_shell}" =~ ^[Nn]$ ]]; then
                usermod -s /sbin/nologin "${FRP_USER}" 2>/dev/null || usermod -s /bin/false "${FRP_USER}"
                echo -e "${GREEN}已修正 shell${NC}"
            fi
        fi
    else
        echo -e "${BLUE}创建专用用户 ${FRP_USER}（非登录）...${NC}"
        if useradd -r -s /sbin/nologin -M "${FRP_USER}" 2>/dev/null; then
            echo -e "${GREEN}✓ 用户创建成功${NC}"
        else
            if useradd -s /bin/false "${FRP_USER}"; then
                echo -e "${GREEN}✓ 用户创建成功（备选参数）${NC}"
            else
                echo -e "${RED}✗ 用户创建失败${NC}" >&2
                exit 1
            fi
        fi
    fi
    
    if ! getent group "${FRP_USER}" &>/dev/null; then
        groupadd -r "${FRP_USER}" 2>/dev/null || true
    fi
    
    echo -e "${BLUE}配置目录权限...${NC}"
    mkdir -p "${FRP_DIR}"
    chown -R "${FRP_USER}:${FRP_USER}" "${FRP_DIR}"
    chmod 755 "${FRP_DIR}"
    
    if [[ -f "${FRP_DIR}/frps" ]]; then
        chmod 755 "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
        chown root:root "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
    fi
    
    mkdir -p "${FRP_DIR}/logs"
    chown "${FRP_USER}:${FRP_USER}" "${FRP_DIR}/logs"
    chmod 750 "${FRP_DIR}/logs"
    
    echo -e "${GREEN}✓ 权限配置完成${NC}"
    
    check_privileged_ports
}

check_privileged_ports() {
    local config_file="${FRP_DIR}/frps.toml"
    if [[ -f "${config_file}" ]]; then
        local http_port=$(grep -E "^vhostHTTPPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
        local https_port=$(grep -E "^vhostHTTPSPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
        
        if [[ -n "${http_port}" && "${http_port}" -lt 1024 ]] || [[ -n "${https_port}" && "${https_port}" -lt 1024 ]]; then
            echo -e "\n${YELLOW}检测到特权端口配置${NC}"
            if command -v setcap &>/dev/null; then
                setcap 'cap_net_bind_service=+ep' "${FRP_DIR}/frps" 2>/dev/null || true
                setcap 'cap_net_bind_service=+ep' "${FRP_BIN_DIR}/frps" 2>/dev/null || true
                echo -e "${GREEN}✓ 已授权绑定特权端口${NC}"
            fi
        fi
    fi
}

#==================================================
# 防火墙配置模块
#==================================================

parse_frp_ports() {
    local config_file="${FRP_DIR}/frps.toml"
    local ports=()
    
    if [[ ! -f "${config_file}" ]]; then
        echo ""
        return
    fi
    
    local bind_port=$(grep -E "^bindPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${bind_port}" ]] && ports+=("${bind_port}/tcp")
    
    local web_port=$(grep -E "^webServer\.port\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${web_port}" ]] && ports+=("${web_port}/tcp")
    
    local http_port=$(grep -E "^vhostHTTPPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${http_port}" ]] && ports+=("${http_port}/tcp")
    
    local https_port=$(grep -E "^vhostHTTPSPort\s*=" "${config_file}" | head -1 | grep -o '[0-9]*' | head -1)
    [[ -n "${https_port}" ]] && ports+=("${https_port}/tcp")
    
    while IFS= read -r line; do
        if [[ "${line}" =~ single\ *=\ *([0-9]+) ]]; then
            ports+=("${BASH_REMATCH[1]}/tcp")
        fi
        if [[ "${line}" =~ start\ *=\ *([0-9]+) ]]; then
            local start_port="${BASH_REMATCH[1]}"
            if [[ "${line}" =~ end\ *=\ *([0-9]+) ]]; then
                local end_port="${BASH_REMATCH[1]}"
                ports+=("${start_port}-${end_port}/tcp")
            fi
        fi
    done < <(grep -A 5 "allowPorts" "${config_file}" 2>/dev/null || true)
    
    printf "%s\n" "${ports[@]}" | sort -u | tr '\n' ' '
}

setup_firewall_interactive() {
    local ports_str=$(parse_frp_ports)
    
    echo -e "\n${BLUE}=== 防火墙配置 ===${NC}"
    
    if [[ -z "${ports_str}" ]]; then
        echo -e "${YELLOW}未检测到端口配置，跳过${NC}"
        return 0
    fi
    
    echo -e "${CYAN}根据 frps.toml 检测到以下端口：${NC}"
    for port in ${ports_str}; do
        echo -e "  • ${YELLOW}${port}${NC}"
    done
    
    echo ""
    read -p "是否配置防火墙开放以上端口？ [Y/n/skip]: " fw_choice
    
    case "${fw_choice}" in
        [Nn]|[Ss]*) 
            echo -e "${YELLOW}已跳过防火墙配置${NC}"
            return 0
            ;;
        *)
            configure_firewall "${ports_str}"
            ;;
    esac
}

configure_firewall() {
    local ports="$1"
    
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo -e "${BLUE}配置 Firewalld...${NC}"
        for port in ${ports}; do
            local port_num=${port%/*}
            local proto=${port#*/}
            firewall-cmd --permanent --add-port="${port_num}/${proto}" 2>/dev/null || true
        done
        firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}✓ Firewalld 配置完成${NC}"
        
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${BLUE}配置 UFW...${NC}"
        for port in ${ports}; do
            ufw allow "${port}" comment 'FRP' 2>/dev/null || true
        done
        echo -e "${GREEN}✓ UFW 配置完成${NC}"
        
    elif command -v iptables &>/dev/null; then
        echo -e "${BLUE}配置 iptables...${NC}"
        for port in ${ports}; do
            local port_num=${port%/*}
            local proto=${port#*/}
            iptables -I INPUT -p "${proto}" --dport "${port_num}" -j ACCEPT 2>/dev/null || true
        done
        echo -e "${GREEN}✓ iptables 配置完成${NC}"
    else
        echo -e "${YELLOW}! 未检测到防火墙工具${NC}"
        echo -e "请手动开放端口：${ports}"
    fi
}

#==================================================
# 安装/升级功能
#==================================================

backup_config() {
    if [[ -d "${FRP_DIR}" ]]; then
        local backup_dir="${FRP_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}备份配置到: ${backup_dir}${NC}"
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
                cp "${backup_dir}/${file}" "${FRP_DIR}/" 2>/dev/null && echo -e "  恢复: ${file}" || true
            fi
        done
        chown -R "${FRP_USER}:${FRP_USER}" "${FRP_DIR}"/*.toml 2>/dev/null || true
    fi
}

create_default_config() {
    local random_token=$(openssl rand -base64 16 2>/dev/null || tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    local admin_pass=$(openssl rand -base64 12 2>/dev/null || echo "admin123")
    
    cat > "${FRP_DIR}/frps.toml" << EOF
# FRP 服务端配置
bindPort = 7000
bindAddr = "0.0.0.0"

auth.method = "token"
auth.token = "${random_token}"

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${admin_pass}"

transport.tcpMux = true
heartbeatTimeout = 90

log.to = "./logs/frps.log"
log.level = "info"
log.maxDays = 30
EOF

    chown "${FRP_USER}:${FRP_USER}" "${FRP_DIR}/frps.toml"
    chmod 640 "${FRP_DIR}/frps.toml"

    cat > "${FRP_DIR}/frpc.toml" << EOF
serverAddr = "YOUR_SERVER_IP"
serverPort = 7000

auth.method = "token"
auth.token = "${random_token}"

webServer.addr = "127.0.0.1"
webServer.port = 7400

log.to = "./logs/frpc.log"
log.level = "info"
log.maxDays = 30

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
transport.useEncryption = true
EOF

    chown "${FRP_USER}:${FRP_USER}" "${FRP_DIR}/frpc.toml"
    chmod 640 "${FRP_DIR}/frpc.toml"
    
    echo -e "${GREEN}配置文件已生成:${NC}"
    echo -e "  Token: ${CYAN}${random_token}${NC}"
    echo -e "  管理密码: ${CYAN}${admin_pass}${NC}"
}

install_systemd_services() {
    ln -sf "${FRP_DIR}/frps" "${FRP_BIN_DIR}/frps"
    ln -sf "${FRP_DIR}/frpc" "${FRP_BIN_DIR}/frpc"
    
    cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=FRP Server
After=network-online.target

[Service]
Type=simple
User=${FRP_USER}
Group=${FRP_USER}
Restart=on-failure
WorkingDirectory=${FRP_DIR}
ExecStart=${FRP_BIN_DIR}/frps -c ${FRP_DIR}/frps.toml
LimitNOFILE=1048576
StandardOutput=append:${FRP_DIR}/logs/frps-systemd.log
StandardError=append:${FRP_DIR}/logs/frps-systemd.log
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${FRP_DIR}/logs

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/frpc.service << EOF
[Unit]
Description=FRP Client
After=network-online.target

[Service]
Type=simple
User=${FRP_USER}
Group=${FRP_USER}
Restart=on-failure
WorkingDirectory=${FRP_DIR}
ExecStart=${FRP_BIN_DIR}/frpc -c ${FRP_DIR}/frpc.toml
LimitNOFILE=1048576
StandardOutput=append:${FRP_DIR}/logs/frpc-systemd.log
StandardError=append:${FRP_DIR}/logs/frpc-systemd.log
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${FRP_DIR}/logs

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}Systemd 服务已安装${NC}"
}

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
    
    # 获取版本（修复：检查返回值）
    local latest_version
    if ! latest_version=$(get_latest_version); then
        echo -e "${RED}无法获取版本信息，安装中止${NC}" >&2
        exit 1
    fi
    
    # 再次检查版本号是否为空
    if [[ -z "${latest_version}" ]]; then
        echo -e "${RED}错误：获取到的版本号为空${NC}" >&2
        exit 1
    fi
    
    echo -e "目标版本: ${GREEN}${latest_version}${NC}"
    
    if [[ "${is_upgrade}" == "true" ]]; then
        local current_version=$(get_installed_version)
        if [[ "${current_version}" == "${latest_version}" ]]; then
            echo -e "${YELLOW}当前已是最新版本${NC}"
            read -p "是否强制重新安装？[y/N]: " force_install
            if [[ ! "${force_install}" =~ ^[Yy]$ ]]; then
                systemctl start frps 2>/dev/null || true
                return 0
            fi
        fi
    fi
    
    # 下载
    local temp_extract_dir=$(download_frp "${latest_version}")
    
    if [[ ! -d "${temp_extract_dir}" ]]; then
        echo -e "${RED}错误：解压目录不存在${NC}" >&2
        exit 1
    fi
    
    cd /
    
    if [[ "${is_upgrade}" == "true" ]]; then
        cp "${temp_extract_dir}/frps" "${FRP_DIR}/"
        cp "${temp_extract_dir}/frpc" "${FRP_DIR}/"
        chmod 755 "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
        restore_config "${backup_dir}"
    else
        rm -rf "${FRP_DIR}"/*
        cp -r "${temp_extract_dir}"/* "${FRP_DIR}/"
        chmod 755 "${FRP_DIR}/frps" "${FRP_DIR}/frpc"
        create_default_config
    fi
    
    # 清理临时目录
    local temp_base=$(dirname "${temp_extract_dir}")
    if [[ -d "${temp_base}" && "${temp_base}" == "/tmp"* ]]; then
        rm -rf "${temp_base}"
    fi
    
    setup_frp_user
    install_systemd_services
    
    echo "${latest_version}" > "${FRP_VERSION_FILE}"
    chown "${FRP_USER}:${FRP_USER}" "${FRP_VERSION_FILE}"
    
    echo -e "\n${GREEN}安装/升级完成！${NC}"
    
    setup_firewall_interactive
    
    echo -e "\n${YELLOW}=== 后续步骤 ===${NC}"
    if [[ "${is_upgrade}" != "true" ]]; then
        echo -e "1. 编辑服务端: ${BLUE}nano ${FRP_DIR}/frps.toml${NC}"
        echo -e "2. 启动: ${BLUE}systemctl start frps && systemctl enable frps${NC}"
        echo -e "3. 客户端编辑: ${BLUE}nano ${FRP_DIR}/frpc.toml${NC}（修改 serverAddr）"
    else
        systemctl restart frps 2>/dev/null || echo -e "${YELLOW}frps 启动失败${NC}"
        systemctl restart frpc 2>/dev/null || true
    fi
}

uninstall_frp() {
    echo -e "${RED}正在卸载 FRP...${NC}"
    
    systemctl stop frps 2>/dev/null || true
    systemctl stop frpc 2>/dev/null || true
    systemctl disable frps 2>/dev/null || true
    systemctl disable frpc 2>/dev/null || true
    
    rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
    systemctl daemon-reload
    
    rm -f "${FRP_BIN_DIR}/frps" "${FRP_BIN_DIR}/frpc"
    
    if [[ -d "${FRP_DIR}" ]]; then
        local backup_dir="${FRP_DIR}.backup.uninstall.$(date +%Y%m%d_%H%M%S)"
        mv "${FRP_DIR}" "${backup_dir}"
        echo -e "${YELLOW}配置已备份至: ${backup_dir}${NC}"
    fi
    
    read -p "是否删除用户 ${FRP_USER}？[y/N]: " del_user
    if [[ "${del_user}" =~ ^[Yy]$ ]]; then
        userdel "${FRP_USER}" 2>/dev/null && echo -e "${GREEN}用户已删除${NC}" || echo -e "${YELLOW}用户删除失败${NC}"
    fi
    
    echo -e "${GREEN}卸载完成${NC}"
}

show_status() {
    echo -e "\n${BLUE}=== FRP 状态 ===${NC}"
    
    if check_installed; then
        echo -e "安装状态: ${GREEN}已安装${NC} ($(get_installed_version))"
        echo -e "安装目录: ${FRP_DIR}"
        
        if id -u "${FRP_USER}" &>/dev/null; then
            echo -e "运行用户: ${GREEN}${FRP_USER}${NC}"
        else
            echo -e "运行用户: ${RED}不存在${NC}"
        fi
        
        echo -e "\n${CYAN}服务状态:${NC}"
        for svc in frps frpc; do
            if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
                local status=$(systemctl is-active ${svc} 2>/dev/null || echo "stopped")
                if [[ "${status}" == "active" ]]; then
                    echo -e "  ${svc}: ${GREEN}运行中${NC}"
                else
                    echo -e "  ${svc}: ${RED}${status}${NC}"
                fi
            fi
        done
        
        local ports=$(parse_frp_ports)
        [[ -n "${ports}" ]] && echo -e "\n${CYAN}配置端口:${NC} ${ports}"
    else
        echo -e "安装状态: ${RED}未安装${NC}"
    fi
}

# 菜单
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}     FRP 安装管理脚本 v3.2${NC}"
        echo -e "${GREEN}========================================${NC}"
        
        local install_status="${RED}未安装${NC}"
        local version_info=""
        if check_installed; then
            install_status="${GREEN}已安装${NC}"
            version_info="($(get_installed_version))"
        fi
        echo -e "当前状态: ${install_status} ${version_info}"
        echo ""
        
        echo "1. 安装 FRP（最新版）"
        echo "2. 升级 FRP（保留配置）"
        echo "3. 卸载 FRP"
        echo "4. 查看状态"
        echo "5. 服务管理"
        echo "6. 配置防火墙"
        echo "7. 编辑服务端配置"
        echo "8. 编辑客户端配置"
        echo "0. 退出"
        echo ""
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1)
                if check_installed; then
                    read -p "已安装，是否重新安装？将备份配置 [y/N]: " confirm
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
                service_menu
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

service_menu() {
    while true; do
        echo -e "\n${CYAN}=== 服务管理 ===${NC}"
        echo "1.启动frps 2.停止frps 3.重启frps 4.状态frps 5.日志frps"
        echo "6.启动frpc 7.停止frpc 8.重启frpc 9.状态frpc 10.日志frpc"
        echo "0.返回"
        read -p "选择: " n
        case $n in
            1) systemctl start frps && echo "已启动" || echo "失败" ;;
            2) systemctl stop frps ;;
            3) systemctl restart frps ;;
            4) systemctl status frps --no-pager ;;
            5) journalctl -u frps -n 50 --no-pager ;;
            6) systemctl start frpc ;;
            7) systemctl stop frpc ;;
            8) systemctl restart frpc ;;
            9) systemctl status frpc --no-pager ;;
            10) journalctl -u frpc -n 50 --no-pager ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

# 入口
check_root
show_menu
