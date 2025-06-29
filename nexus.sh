#!/bin/bash
set -e

# 配置变量
SCREEN_NAME="nexus"
MONITOR_NAME="nexus-monitor"
NODE_ID_FILE="$HOME/.nexus/node-id"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 安装依赖
install_dependencies() {
    log_info "检查系统依赖..."

    # 安装 screen
    if ! command -v screen >/dev/null 2>&1; then
        log_info "安装 screen..."
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y screen
        elif command -v yum >/dev/null 2>&1; then
            yum install -y screen
        else
            log_error "无法自动安装 screen，请手动安装"
            exit 1
        fi
    fi

    # 安装 nexus-network
    if ! command -v nexus-network >/dev/null 2>&1; then
        log_info "安装 nexus-network..."
        curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh

        # 更新当前会话的 PATH
        export PATH="$HOME/.nexus/bin:$PATH"

        if [ -f "$HOME/.nexus/bin/nexus-network" ]; then
            ln -sf "$HOME/.nexus/bin/nexus-network" "/usr/local/bin/nexus-network" 2>/dev/null || true
            log_success "nexus-network 安装完成"
        else
            log_error "nexus-network 安装失败"
            exit 1
        fi
    fi

    log_success "所有依赖已准备就绪"
}

# 获取或设置 node-id
setup_node_id() {
    # 如果已经有 node-id 文件，直接返回
    if [ -f "$NODE_ID_FILE" ] && [ -s "$NODE_ID_FILE" ]; then
        local existing_id=$(cat "$NODE_ID_FILE" | tr -d '\n\r' | xargs)
        if [ -n "$existing_id" ]; then
            log_info "使用已保存的 Node ID: $existing_id"
            return 0
        fi
    fi

    # 需要输入新的 node-id
    log_warning "需要设置 Node ID"
    echo "请输入您的 node-id（例如：6645576）："

    local node_id=""
    while [ -z "$node_id" ]; do
        echo -n "Node ID: "
        read node_id
        node_id=$(echo "$node_id" | tr -d '\n\r' | xargs)

        if [ -z "$node_id" ]; then
            log_error "Node ID 不能为空，请重新输入"
        elif [[ ! "$node_id" =~ ^[a-zA-Z0-9]+$ ]]; then
            log_error "Node ID 格式不正确，请输入字母数字组合"
            node_id=""
        fi
    done

    # 保存 node-id
    mkdir -p "$(dirname "$NODE_ID_FILE")"
    echo "$node_id" > "$NODE_ID_FILE"
    log_success "Node ID 已保存: $node_id"
}

# 获取 node-id
get_node_id() {
    if [ -f "$NODE_ID_FILE" ] && [ -s "$NODE_ID_FILE" ]; then
        cat "$NODE_ID_FILE" | tr -d '\n\r' | xargs
    else
        echo ""
    fi
}

# 检查节点是否运行
is_node_running() {
    screen -list 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"
}

# 检查监控是否运行
is_monitor_running() {
    screen -list 2>/dev/null | grep -q "\.${MONITOR_NAME}[[:space:]]"
}

# 启动节点 (包含自动重启功能)
start_node() {
    # 检查是否已在运行
    if is_node_running; then
        log_warning "节点已在运行"
        return 0
    fi

    # 安装依赖
    install_dependencies

    # 确保有 node-id
    setup_node_id
    local node_id=$(get_node_id)

    if [ -z "$node_id" ]; then
        log_error "无法获取 Node ID"
        return 1
    fi

    log_info "启动节点 (Node ID: $node_id)"

    # 启动节点主进程
    screen -dmS "$SCREEN_NAME" bash -c "
        export PATH=\"$HOME/.nexus/bin:/usr/local/bin:\$PATH\"
        cd \$HOME
        echo '==============================='
        echo '节点启动时间: \$(date)'
        echo 'Node ID: $node_id'
        echo '==============================='

        while true; do
            echo '尝试启动 nexus-network...'
            if nexus-network start --node-id '$node_id'; then
                echo 'nexus-network 正常退出'
            else
                echo 'nexus-network 异常退出，5秒后重试...'
            fi
            sleep 5
        done
    "

    # 启动监控进程 (自动重启功能)
    screen -dmS "$MONITOR_NAME" bash -c "
        while true; do
            sleep 180  # 3分钟检查一次

            if ! screen -list 2>/dev/null | grep -q '\.${SCREEN_NAME}[[:space:]]'; then
                echo \"\$(date): 检测到节点停止，正在重启...\"

                screen -dmS '$SCREEN_NAME' bash -c \"
                    export PATH=\\\"$HOME/.nexus/bin:/usr/local/bin:\\\$PATH\\\"
                    cd \\\$HOME
                    echo '==============================='
                    echo '自动重启时间: \\\$(date)'
                    echo 'Node ID: $node_id'
                    echo '==============================='

                    while true; do
                        echo '尝试启动 nexus-network...'
                        if nexus-network start --node-id '$node_id'; then
                            echo 'nexus-network 正常退出'
                        else
                            echo 'nexus-network 异常退出，5秒后重试...'
                        fi
                        sleep 5
                    done
                \"
                echo \"\$(date): 节点重启完成\"
            fi
        done
    "

    sleep 3
    if is_node_running; then
        log_success "节点启动成功 (已启用自动重启)"
        return 0
    else
        log_error "节点启动失败"
        return 1
    fi
}

# 显示状态
show_status() {
    echo "=================================="
    echo "Nexus 节点状态"
    echo "=================================="

    # Node ID
    local node_id=$(get_node_id)
    if [ -n "$node_id" ]; then
        echo "Node ID: $node_id"
    else
        echo "Node ID: 未设置"
    fi

    # 节点状态
    if is_node_running; then
        echo -e "节点状态: ${GREEN}运行中${NC}"
    else
        echo -e "节点状态: ${RED}已停止${NC}"
    fi

    # 监控状态
    if is_monitor_running; then
        echo -e "自动重启: ${GREEN}已启用${NC}"
    else
        echo -e "自动重启: ${RED}已禁用${NC}"
    fi

    # 程序状态
    if command -v nexus-network >/dev/null 2>&1; then
        echo "程序: nexus-network 已安装"
    else
        echo "程序: nexus-network 未安装"
    fi

    echo "=================================="
}

# 查看日志
view_logs() {
    if is_node_running; then
        log_info "进入节点日志查看 (按 Ctrl+A 然后 D 退出)"
        sleep 1
        screen -r "$SCREEN_NAME"
    else
        log_error "节点未运行"
    fi
}

# 删除节点
delete_node() {
    echo "确认删除节点吗? 这将停止所有进程并删除配置 (y/N): "
    read confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在删除节点..."

        # 停止所有相关的 screen 会话
        screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true
        screen -S "$MONITOR_NAME" -X quit 2>/dev/null || true

        # 删除配置文件
        rm -f "$NODE_ID_FILE"

        sleep 2
        log_success "节点已完全删除"
    else
        log_info "操作已取消"
    fi
}

# 主循环
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}===== Nexus 节点管理器 =====${NC}"
        echo "1. 启动节点 (含自动重启)"
        echo "2. 查看节点状态"
        echo "3. 查看节点日志"
        echo "4. 删除节点"
        echo "5. 退出"
        echo "================================="

        # 显示当前状态
        if is_node_running; then
            echo -e "当前状态: ${GREEN}运行中${NC}"
        else
            echo -e "当前状态: ${RED}已停止${NC}"
        fi

        local node_id=$(get_node_id)
        if [ -n "$node_id" ]; then
            echo -e "Node ID: ${BLUE}$node_id${NC}"
        else
            echo -e "Node ID: ${YELLOW}未设置${NC}"
        fi
        echo "================================="

        echo -n "请选择操作 (1-5): "
        read choice

        case $choice in
            1)
                start_node
                echo ""
                echo "按 Enter 继续..."
                read
                ;;
            2)
                show_status
                echo ""
                echo "按 Enter 继续..."
                read
                ;;
            3)
                view_logs
                ;;
            4)
                delete_node
                echo ""
                echo "按 Enter 继续..."
                read
                ;;
            5)
                echo -e "${GREEN}退出程序${NC}"
                exit 0
                ;;
            *)
                log_error "无效选项，请输入 1-5"
                echo "按 Enter 继续..."
                read
                ;;
        esac
    done
}

# 命令行参数处理
case "${1:-}" in
    start)
        install_dependencies
        start_node
        ;;
    status)
        show_status
        ;;
    logs)
        view_logs
        ;;
    delete)
        delete_node
        ;;
    *)
        main_menu
        ;;
esac
