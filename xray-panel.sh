#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"  # 修复缺失的闭合引号

# 主菜单
# clear 在没有 TERM 的环境（cron、管道、部分 SSH）会报
# "TERM environment variable not set" 并刷一堆错。
_srv_clear() {
  if [ -t 1 ] && [ -n "${TERM:-}" ]; then clear; fi
}

show_menu() {
    # 获取服务状态
    xrayls_server_status=$(systemctl is-active xrayls.service 2>/dev/null || echo "inactive")

    # 生成状态文本
    if [[ "$xrayls_server_status" == "active" ]]; then
        xrayls_server_status_text="${GREEN}启动${PLAIN}"
    else
        xrayls_server_status_text="${RED}未启动${PLAIN}"
    fi

    # 使用单引号和here-doc格式避免转义问题
    _srv_clear
    cat << "EOF"

                       |\__/,|   (\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xrayls
       -----------------------------------------

EOF
    echo -e "
${GREEN}xrayls 管理脚本${PLAIN}
----------------------
${GREEN}1.${PLAIN} 安装/更新 xray（自动检测版本：旧版升级、最新则跳过）
${GREEN}2.${PLAIN} 卸载 xray
${GREEN}3.${PLAIN} 查看客户端配置
${GREEN}4.${PLAIN} 查询服务状态
${GREEN}5.${PLAIN} 添加节点
${GREEN}6.${PLAIN} 校验配置/重启服务
${GREEN}7.${PLAIN} 出站管理（outbound）
${GREEN}8.${PLAIN} 分流规则管理（split）
${GREEN}9.${PLAIN} 反向代理管理（reverse）
${GREEN}10.${PLAIN} 分享管理（share）
${GREEN}11.${PLAIN} 节点管理（node）
${GREEN}12.${PLAIN} 自检（校验通用能力）
${GREEN}13.${PLAIN} DNS 管理（dns）
${GREEN}14.${PLAIN} 日志（logs）
${GREEN}15.${PLAIN} 预置建节点（mknode）
${GREEN}16.${PLAIN} 预置批量生成（preset_batch）
${GREEN}17.${PLAIN} 证书管理（cert）
${GREEN}18.${PLAIN} Nginx 站点管理（nginx_site）
${GREEN}19.${PLAIN} 分享服务（share_service）
${GREEN}0.${PLAIN} 退出脚本
----------------------
xrayls 服务状态: ${xrayls_server_status_text}
----------------------"

    # 同理: 按键用尽时退出, 不要拿空 choice 反复重画
    read -r -p "请输入选项 [0-9]: " choice || exit 0

    case "${choice}" in
        0) _srv_clear; exit 0 ;;
        1) run_xray_install ;;
        2) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/uninstall_xray.sh) ;;
        3) show_xray_configs ;;
        4) systemctl status xrayls --no-pager ;;
        5) add_node_menu ;;
        6) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/verify.sh) ;;
        7) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/outbound.sh) ;;
        8) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/split.sh) ;;
        9) reverse_menu ;;
        10) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/share.sh) ;;
        11) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/node.sh) ;;
        12) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/tools/check_libs.sh) ;;
        13) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/dns.sh) ;;
        14) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/logs.sh) ;;
        15) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/mknode.sh) ;;
        16) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/tools/preset_batch.sh) --help ;;
        17) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/cert.sh) ;;
        18) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/nginx_site.sh) ;;
        19) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/share_service.sh) menu ;;

        *) echo -e "${RED}无效的选项 ${choice}${PLAIN}" ;;
    esac

    # 回车返回。**EOF 必须当作退出**。
    #
    # read 在 stdin 用尽时返回非 0, 而这一行原来只是 `read ... && echo`,
    # 后面无条件回到 while 顶部 —— 于是脚本无限重画菜单, 刷屏到天荒地老,
    # 自动化里表现就是"卡死到超时"。
    # 触发路径很常见: `bash xray-panel.sh < /dev/null`、管道喂完按键、
    # 从别的脚本里调用。交互时看不出来, 一进自动化就挂。
    echo
    read -r -p "按回车键返回主菜单..." _ || exit 0
    echo
}

# 反向代理管理子菜单（reverse）
reverse_menu() {
    while true; do
        _srv_clear
        echo -e "
${GREEN}反向代理管理 (reverse)${PLAIN}
----------------------
${GREEN}1.${PLAIN} 服务端管理（xrayserver-reverse，运行在家/入口侧）
${GREEN}2.${PLAIN} 客户端管理（xrayclient-reverse，运行在RN/回连侧）
${GREEN}0.${PLAIN} 返回主菜单
----------------------"
        # EOF 当退出, 否则按键用尽后无限重画子菜单
        read -r -p "请输入选项 [0-2]: " rc || return
        case "${rc}" in
            1) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/fd/xrayserver-reverse.sh) ;;
            2) bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/fd/xrayclient-reverse.sh) ;;
            0) return ;;
            *) echo -e "${RED}无效的选项 ${rc}${PLAIN}" ;;
        esac
        echo
        read -r -p "按回车键返回子菜单..." _ || return
        echo
    done
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        # 检查 env 文件格式是否正确
        if grep -qEv '^[A-Za-z_][A-Za-z0-9_]*=".*"$' "$ENV_FILE"; then
            echo "⚠ env 文件格式异常：$ENV_FILE"
            return 1
        fi

        # 安全加载
        set -a
        source "$ENV_FILE"
        set +a
        echo "已加载 env：$ENV_FILE"
    else
        echo "env 文件不存在：$ENV_FILE"
    fi
}
# 统一安装/更新入口：bin/xray_install.sh
# 幂等：已安装且为最新版本时跳过下载；旧版本自动升级；并重建基础配置、验证并重启 xrayls
XRAY_INSTALL_URL="https://github.com/mi1314cat/xray--core/raw/refs/heads/main/bin/xray_install.sh"

run_xray_install() {
    bash <(curl -fsSL "$XRAY_INSTALL_URL") || {
        echo -e "${RED}xrayls 安装/更新失败，请查看上方错误信息${PLAIN}"
        return 1
    }
}
show_xray_configs() {
    local out_dir="/root/catmi/xray/out"

    if [[ ! -d "$out_dir" ]]; then
        echo -e "${RED}目录不存在：$out_dir${PLAIN}"
        return
    fi

    echo -e "${GREEN}===== TXT 配置文件 =====${PLAIN}"
    for f in "$out_dir"/*.txt; do
        [[ -e "$f" ]] || { echo "无 TXT 文件"; break; }
        echo -e "\n===== $f ====="
        cat "$f"
    done

    echo -e "\n${GREEN}===== YAML 配置文件 =====${PLAIN}"
    for f in "$out_dir"/*.yaml "$out_dir"/*.yml; do
        [[ -e "$f" ]] || { echo "无 YAML 文件"; break; }
        echo -e "\n===== $f ====="
        cat "$f"
    done
}

add_node_menu() {
    _srv_clear
    echo -e "
${GREEN}添加节点${PLAIN}
----------------------
${GREEN}1.${PLAIN} 添加 Tunnel 节点
${GREEN}2.${PLAIN} 添加 Hysteria2 节点
${GREEN}3.${PLAIN} 添加 SOCKS5 节点（无加密）
${GREEN}4.${PLAIN} 添加 VLESS-ECN 节点（tcp传输）
${GREEN}5.${PLAIN} 添加 HTTP 节点（无加密）
${GREEN}6.${PLAIN} 添加 VLESS-xHTTP TLS 节点
${GREEN}7.${PLAIN} 添加 Reality 节点（vision + ML-KEM-768，最高配置）
${GREEN}8.${PLAIN} 添加 Shadowsocks-2022 节点（aes-256-gcm，最高配置）
${GREEN}9.${PLAIN} 添加 Trojan 节点（Reality 安全层，最高配置）

---------------------- Argo 节点 ----------------------
${GREEN}10.${PLAIN} 添加 固定 Argo 节点
${GREEN}11.${PLAIN} 添加 临时 Argo 节点

------------- Batch Generator -------------
${GREEN}12.${PLAIN} 全协议一键生成（自动端口，统一校验，仅 reload 一次）

${GREEN}0.${PLAIN} 返回主菜单
----------------------"

    read -r -p "请输入选项 [0-12]: " nchoice || return

    case "${nchoice}" in
        0) return ;;

        1)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/tunnel.sh)
            systemctl restart xrayls.service
            ;;

        2)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/hysteria2.sh)
            systemctl restart xrayls.service
            ;;

        3)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/sock5.sh)
            systemctl restart xrayls.service
            ;;

        4)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/vlessecn.sh)
            systemctl restart xrayls.service
            ;;

        5)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/http.sh)
            systemctl restart xrayls.service
            ;;

        6)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/vlessxhttpecn.sh)
            systemctl restart xrayls.service
            ;;

        7)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/Reality.sh)
            systemctl restart xrayls.service
            ;;

        8)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/Shadowsocks.sh)
            systemctl restart xrayls.service
            ;;

        9)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/Trojan.sh)
            systemctl restart xrayls.service
            ;;

        10)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/GDargo.sh)
            systemctl restart xrayls.service
            ;;

        11)
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lsargo.sh)
            systemctl restart xrayls.service
            ;;

        12)
            # Batch Generator 收尾自带统一校验+一次重启, 这里不再 restart
            bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/batch.sh)
            ;;

        *)
            echo -e "${RED}无效的选项${PLAIN}"
            ;;
    esac

    return
}

# 主程序循环。show_menu 内部在 EOF 时 exit, 所以不会无限刷屏。
while true; do
    show_menu
done
