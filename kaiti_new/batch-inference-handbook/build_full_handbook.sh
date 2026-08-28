#!/usr/bin/env bash
set -euo pipefail

handbook_dir="$(cd "$(dirname "$0")" && pwd)"
output_file="$handbook_dir/FULL_HANDBOOK.md"
temp_file="$(mktemp)"

cd "$handbook_dir"

printf '%s\n\n' '# Batch Inference 项目手册（全文合并版）' > "$temp_file"
printf '%s\n\n' '> 本文件由模块化 Markdown 机械合并，用于离线保存和全文搜索。事实源是同目录 README、QUICK_REFERENCE 及 00-10 子目录；修改模块文档后重新运行 build_full_handbook.sh。' >> "$temp_file"

for relative_file in README.md QUICK_REFERENCE.md VERIFICATION.md \
  00-overview/*.md \
  01-domain-model/*.md \
  02-task-ingestion/*.md \
  03-scheduling/*.md \
  04-execution/*.md \
  05-progress-and-results/*.md \
  06-concurrency-autotuner/*.md \
  07-reliability/*.md \
  08-platform-capabilities/*.md \
  09-reference/*.md \
  10-experience-and-interview/*.md; do
  file="$relative_file"
  printf '%s\n\n' '---' >> "$temp_file"
  printf '来源：`%s`\n\n' "$relative_file" >> "$temp_file"
  sed 's/^# /## /' "$file" >> "$temp_file"
  printf '\n' >> "$temp_file"
done

mv "$temp_file" "$output_file"
printf 'generated %s\n' "$output_file"
