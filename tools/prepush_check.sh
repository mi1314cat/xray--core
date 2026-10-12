#!/usr/bin/env bash
# 上传前验证 —— 用户要求: 每次上传之前必须先验证, 验证过了才上传。
#
# 为什么要有这个脚本而不是"记得跑一下测试"
#   验证这件事一旦靠记性, 漏掉的那一次恰好是最贵的一次 (推上去才发现
#   语法错 / 测试红 / 把不该传的文件传了)。把它写成**没有它就别推**的
#   单条命令, 才是可靠的做法。
#
# 用法:
#   bash tools/prepush_check.sh <候选目录> [测试目录]
#
#   候选目录  = 准备上传的那份 (通常是干净的 clone + 覆盖后的工作树)
#   测试目录  = 跑测试的那份 (省略则与候选目录相同)
#
# 退出码 0 = 全部通过, 可以推。非 0 = 有项目没过, **不要推**。

set -uo pipefail

CAND="${1:-.}"
TESTED="${2:-$CAND}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
FAIL=0
STEP=0

say()  { printf '%s\n' "$*"; }
head1() { STEP=$((STEP+1)); printf '\n%s[%d] %s%s\n' "$DIM" "$STEP" "$1" "$RST"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$1"; }

[ -d "$CAND" ] || { say "候选目录不存在: $CAND"; exit 2; }

say "════════════════════════════════════════════════════"
say " 上传前验证    候选: $CAND"
[ "$TESTED" != "$CAND" ] && say "                测试: $TESTED"
say "════════════════════════════════════════════════════"

# ---------------------------------------------------------------- 1. 静态语法
head1 "语法检查"

nsh=0; nbad=0
while IFS= read -r f; do
    nsh=$((nsh+1))
    if ! bash -n "$CAND/$f" 2>/tmp/pp_err; then
        bad "bash -n $f"
        sed -n '1,3{s/^/        /;p}' /tmp/pp_err
        nbad=$((nbad+1))
    fi
done < <(cd "$CAND" && find . -type f -name '*.sh' -not -path './.git/*' | sed 's|^\./||')
# 主入口也要查: 它是 .sh 吗? 不是的话单独补
if [ -f "$CAND/xray-panel.sh" ]; then
    nsh=$((nsh+1))
    bash -n "$CAND/xray-panel.sh" 2>/tmp/pp_err \
        && ok "xray-panel.sh" || { bad "bash -n xray-panel.sh"; sed -n '1,3{s/^/        /;p}' /tmp/pp_err; }
fi
[ "$nbad" -eq 0 ] && ok "$nsh 个 shell 文件语法通过"

npy=0; nbad=0
while IFS= read -r f; do
    npy=$((npy+1))
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$CAND/$f" 2>/tmp/pp_err \
        || { bad "python 语法 $f"; sed -n '1,3{s/^/        /;p}' /tmp/pp_err; nbad=$((nbad+1)); }
done < <(cd "$CAND" && find . -type f -name '*.py' -not -path './.git/*' -not -path '*/__pycache__/*' | sed 's|^\./||')
[ "$nbad" -eq 0 ] && ok "$npy 个 python 文件语法通过"

if command -v shellcheck >/dev/null 2>&1; then
    sc_bad=0; sc_n=0
    while IFS= read -r f; do
        sc_n=$((sc_n+1))
        # 只报 error 级 (SC2xxx 语法/致命), 不报 style/信息级 —— 否则噪声
        # 大到没人看, 久了就等于没开。
        shellcheck -S error -f gcc "$CAND/$f" >/tmp/pp_sc 2>&1 || { sc_bad=$((sc_bad+1)); sed -n '1,3{s/^/        /;p}' /tmp/pp_sc; }
    done < <(cd "$CAND" && find . -type f -name '*.sh' -not -path './.git/*' | sed 's|^\./||')
    [ "$sc_bad" -eq 0 ] && ok "shellcheck -S error: $sc_n 个文件干净" \
                       || bad "shellcheck 发现 $sc_bad 个文件有 error 级问题"
else
    warn "shellcheck 没装, 跳过 (语法检查已覆盖语法错误)"
fi

# ---------------------------------------------------------------- 2. 早退管道
head1 "自检: 早退管道 (SIGPIPE 141)"
# stdout 是数据通道 (分享链接/订阅内容)。所有 UI 输出必须走 >&2。
# 这条规则被人破坏时的典型症状就是 `| head -1` 这类早退管道:
# 上游收到 SIGPIPE 退出 141, 写出来的分享链接是**半截**的。
EARLY='(?<!\|)\|(?!\|)\s*(?:head\b|grep\s+-[A-Za-z]*[qm]\b)'
e_bad=0
while IFS= read -r f; do
    while IFS= read -r hit; do
        ln="${hit%%:*}"
        [[ "${hit#"$ln:"}" =~ ^[[:space:]]*# ]] && continue
        bad "$f:$ln  $(echo "$hit" | cut -d: -f3- | cut -c1-60)"
        e_bad=$((e_bad+1))
    done < <(grep -nE "$EARLY" "$f" 2>/dev/null)
done < <(cd "$CAND" && find . -type f \( -name '*.sh' -o -name '*.py' \) -not -path './.git/*' | sed 's|^\./||')
[ "$e_bad" -eq 0 ] && ok "没有裸的早退管道"

# ---------------------------------------------------------------- 3. 不该上传的东西
head1 "不该上传的文件"
LEAK=0
while IFS= read -r f; do
    rel="${f#$CAND/}"
    case "$rel" in
        *__pycache__*|*.pyc|*.pyo|*~|*.swp|.DS_Store|id_rsa*|*.key|*.pem|*.p12|*.pfx)
            bad "$rel"; LEAK=$((LEAK+1)) ;;
    esac
done < <(find "$CAND" -type f -not -path '*/.git/*')
# 凭据类: 扫一眼有没有把 token/PAT 写进脚本
while IFS= read -r f; do
    if grep -qE 'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}' "$f" 2>/dev/null; then
        bad "$f 里有疑似 GitHub 凭据"; LEAK=$((LEAK+1))
    fi
done < <(cd "$CAND" && find . -type f \( -name '*.sh' -o -name '*.py' -o -name '*.md' \) -not -path './.git/*' | sed 's|^\./||')
[ "$LEAK" -eq 0 ] && ok "没有 __pycache__ / 私钥 / 凭据"

# ---------------------------------------------------------------- 4. 候选 == 被测
head1 "候选目录是否等于跑过测试的那份"
# 这一条最要紧: 测的是 A、推的是 B, 那么"测试通过"证明不了任何事。
# ---- 已知且有意的差异 ----
#
# 实验目录 (xray-ux-lab) 里有一处**故意**与仓库不同: conf/share_client.py
# 被替换成了实验桩。真实实现会去连**生产**分享服务, 而跑测试时绝不能碰生产
# (它会列出生产令牌、真发订阅)。所以这一处差异是设计如此, 不是漏同步。
#
# 但豁免必须是**显式且可见**的: 每次跑都打出来, 而且只能按文件名精确豁免。
# 做成"整个目录都别管"的话, 这个检查当场失效 —— 那还不如不写。
KNOWN_INTENTIONAL_DIFFS=(
    "conf/share_client.py"
)

_exempt() {
    local want="$1" i
    for i in "${KNOWN_INTENTIONAL_DIFFS[@]}"; do
        [ "$i" = "$want" ] && return 0
    done
    return 1
}

if [ "$TESTED" = "$CAND" ]; then
    ok "测试目录与候选目录相同"
else
    diff_n=0; ex_n=0; n_files=0
    while IFS= read -r f; do
        rel="${f#$CAND/}"
        case "$rel" in .git*) continue ;; esac
        n_files=$((n_files+1))
        if [ ! -f "$TESTED/$rel" ] || ! cmp -s "$f" "$TESTED/$rel"; then
            if _exempt "$rel"; then
                warn "豁免: $rel (实验桩, 故意与仓库不同)"
                ex_n=$((ex_n+1))
            elif [ ! -f "$TESTED/$rel" ]; then
                bad "$rel 只在候选里, 测试那份没有 (没被测过)"
                diff_n=$((diff_n+1))
            else
                bad "$rel 两边不一致 (测的不是要推的那份)"
                diff_n=$((diff_n+1))
            fi
        fi
    done < <(find "$CAND" -type f -not -path '*/.git/*')
    [ "$diff_n" -eq 0 ] && ok "$((n_files - ex_n)) 个文件逐字一致$([ "$ex_n" -gt 0 ] && printf ', %d 个按名豁免' "$ex_n")"
fi

# ---------------------------------------------------------------- 5. 测试套件
head1 "测试套件 tools/check_libs.sh"
if [ -f "$TESTED/tools/check_libs.sh" ]; then
    # ★ 实验目录的 conf/share_client.py 是桩, 跑套件必须指向真实现。
    #   少了这一条, 「服务不可达」那两个用例会因为桩的行为而**假失败** ——
    #   而验证脚本一旦自己造出一个假失败, 下次就会被顺手忽略, 那比没验证更糟。
    #   以前这个环境变量只在我的命令行里, 谁忘了设谁就会撞上。
    if [ -z "${SHARE_CLIENT_REAL:-}" ] \
       && grep -q "LAB STUB" "$TESTED/conf/share_client.py" 2>/dev/null; then
        SHARE_CLIENT_REAL="${SHARE_CLIENT_FALLBACK:-/root/xray--core/conf/share_client.py}"
        export SHARE_CLIENT_REAL
        ok "实验桩已识别, SHARE_CLIENT_REAL 指向真实现"
    fi
    ( cd "$TESTED" && timeout 900 bash tools/check_libs.sh ) >/tmp/pp_test 2>&1
    rc=$?
    tail -1 /tmp/pp_test | sed 's/^/  /'
    if [ $rc -eq 0 ] && grep -q '0 失败' /tmp/pp_test; then
        ok "测试全绿"
    else
        bad "测试没全绿 (rc=$rc)"
        grep -E '✗' /tmp/pp_test | sed -n '1,10{s/^/        /;p}'
    fi
else
    warn "找不到 tools/check_libs.sh, 跳过"
fi

# ---------------------------------------------------------------- 6. 真实内核
head1 "真实内核校验 (不是 -test 的全部能力, 但能挡明显坏配置)"
if command -v xray >/dev/null 2>&1; then
    ok "xray 在 PATH"
elif [ -x /usr/local/bin/xray ]; then
    ok "/usr/local/bin/xray"
else
    warn "找不到 xray 二进制, 跳过"
fi

# ---------------------------------------------------------------- 收尾
say ''
say "════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
    printf '%s 全部通过 —— 可以推%s\n' "$GRN" "$RST"
    say "════════════════════════════════════════════════════"
    exit 0
fi
printf '%s 有 %d 项没过 —— 不要推%s\n' "$RED" "$FAIL" "$RST"
say "════════════════════════════════════════════════════"
exit 1