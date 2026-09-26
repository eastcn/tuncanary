#!/usr/bin/env bash
# 运行自带测试运行器 TunCanarySelfTest。任一用例失败返回非零。
# 用法：scripts/test.sh [--list] [过滤词 ...]
#   过滤词按“套件名/用例名”做不区分大小写的子串匹配，多个取并集，例如：
#     scripts/test.sh Core.ClashConfigParser
#     scripts/test.sh "LocalEvaluator/宽限期"
set -euo pipefail

cd "$(dirname "$0")/.."
exec swift run -c debug TunCanarySelfTest "$@"
