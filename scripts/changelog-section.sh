#!/bin/sh
# CHANGELOG.md から「## [X.Y.Z]」の節だけを取り出して標準出力に書く。
#
# 審査に出すときのリリースノートと、GitHub Release の本文の両方で使う。
# 二か所で別々に書くと、片方だけ直したときに食い違う。
#
#   ./scripts/changelog-section.sh 0.1.0

set -eu

version="${1:?usage: changelog-section.sh <version>}"
changelog="${2:-CHANGELOG.md}"

awk -v ver="$version" '
  # 目的の見出しに入ったら拾い始める。見出しそのものは要らない。
  $0 ~ "^## \\[" ver "\\]" { found = 1; next }
  # 次の見出しで止める。
  /^## \[/ { found = 0 }
  found
' "$changelog" |
  # 前後の空行を落とす。App Store のリリースノートは空行から始まると不格好。
  sed -e '/./,$!d' |
  awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }'
