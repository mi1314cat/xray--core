#!/usr/bin/env bash
# ================================================================
# 交互输入 —— 全部脚本共用的读输入实现
#
# 为什么单独抽出来:
#   conf/ 下十几个脚本各自复制了一份 safe_read / clean_input, 于是同一个坑
#   散落在每个文件里。修一次要改十几个地方, 漏掉的那个就会在自动化里刷屏到
#   超时。放在一起才有一个能改对的地方。
#
# 核心: **EOF 当作退出**。
#
#   read 在 stdin 用尽时返回非 0, 而变量保持上一次的值(通常是空)。原来
#   各个 safe_read 都不检查返回值, 于是校验分支会拿着空值反复报
#   "格式无效" —— 无限刷屏, 自动化里表现就是卡死到超时。
#
#   触发路径全是常规操作, 不是边缘情况:
#     · 从别的脚本里 source 调用, stdin 是空的
#     · 管道喂完按键 (printf '1\n' | bash node.sh)
#     · 交互时按 Ctrl-D
#     · CI 里跑
#
#   交互时完全看不出来 —— 所以必须在这里统一堵住。
# ================================================================

# 读一行。EOF 时 exit 0, 而不是返回一个"看起来像空串"的值。
#
# 用 exit 而不是 return: 返回空值的话, 调用方的
#   [[ "$x" =~ ^[0-9]+$ ]] || { print_error "必须是数字"; continue; }
# 会把它当成非法输入继续问下一个问题, 于是又回到死循环。
xr_read() {
  local __prompt="$1" __default="${2-}" __var="${3-__xr_in}" __input=""
  if [ -n "$__default" ]; then
    printf "%s (默认: %s): " "$__prompt" "$__default" >&2
  else
    printf "%s: " "$__prompt" >&2
  fi
  if ! IFS= read -r __input; then
    printf '\n' >&2
    [ -n "${XR_EOF_QUIET:-}" ] || printf '输入已结束，退出\n' >&2
    exit 0
  fi
  __input=$(printf '%s' "$__input" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  printf -v "$__var" '%s' "${__input:-$__default}"
}

# 兼容各脚本原有的名字。conf/ 下十几个文件都定义了同名函数, 统一指到这里。
safe_read() {
  local __out
  xr_read "$1" "${2-}" __out
  printf '%s' "$__out"
}

# 兼容 clean_input: 只做去空白/去 CR, 不带读取。
clean_input() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# 菜单用的选择读取。EOF 时退出。
xr_choice() {
  local __prompt="$1" __input
  printf "%s" "$__prompt" >&2
  if ! IFS= read -r __input; then
    printf '\n' >&2
    exit 0
  fi
  clean_input "$__input"
}
