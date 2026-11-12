#!/usr/bin/env bash
# loc.sh [DIRECTORY]: files, lines, blank, comment and code lines per file type.
# Comments are single-line ones only.

set -euo pipefail

ROOT="${1:-.}"

# File extensions to count (case-insensitive):
EXTS=(
  # shell / scripting
  sh bash zsh fish cmd bat ps1 py rb pl pm lua tcl awk sed
  # systems
  c h cpp cc cxx hpp hh hxx cu cuh zig rs go s asm ld
  # JVM / mobile / .NET
  java kt kts scala groovy gradle swift m mm cs fs dart
  # web
  js mjs cjs jsx ts tsx vue svelte css scss sass less html htm xml xsl svg
  php tmpl tpl j2 jinja ejs hbs
  # data / config / schema
  sql json yml yaml toml ini cfg conf pb proto graphql gql tf hcl
  # functional / other
  hs ml mli ex exs erl clj r jl nim v sol
  # docs / build
  md rst cmake mk
)

# Files matched by exact name:
NAMES=( Makefile makefile Dockerfile CMakeLists.txt Jenkinsfile Vagrantfile )

# Directories to skip:
EXCLUDE_DIRS=(
  .git .svn .hg .idea .vscode node_modules vendor target build dist out bin obj
  __pycache__ .venv venv env .tox .mypy_cache .pytest_cache .gradle .next .cache
  .zig-cache zig-out zig-cache
)

prune=()
for d in "${EXCLUDE_DIRS[@]}"; do
  [ ${#prune[@]} -gt 0 ] && prune+=( -o )
  prune+=( -name "$d" )
done

match=()
for e in "${EXTS[@]}"; do
  [ ${#match[@]} -gt 0 ] && match+=( -o )
  match+=( -iname "*.$e" )
done
for n in "${NAMES[@]}"; do
  match+=( -o -name "$n" )
done

# Count per type (maybe in several batches), then sum and sort:
find "$ROOT" \( "${prune[@]}" \) -prune -o -type f \( "${match[@]}" \) \
     ! -name '*.min.js' ! -name '*.min.css' -print0 |
xargs -0 awk '
BEGIN {
  # Single-line comment prefixes per type:
  split("sh bash zsh fish py rb pl pm tcl awk sed ps1 yml yaml toml ini cfg conf makefile mk dockerfile cmake tf hcl r jl nim ex exs s asm", a, " ")
  for (i in a) cm[a[i]] = "#"
  split("c h cpp cc cxx hpp hh hxx cu cuh zig rs go java kt kts scala groovy gradle swift m mm cs fs dart js mjs cjs jsx ts tsx vue svelte scss less php proto graphql gql sol", b, " ")
  for (i in b) cm[b[i]] = "//"
  split("lua sql hs", c, " ")
  for (i in c) cm[c[i]] = "--"
  cm["bat"] = "::"; cm2["bat"] = "rem"
  cm["cmd"] = "::"; cm2["cmd"] = "rem"
  cm["erl"] = "%"; cm["ml"] = "";  cm["clj"] = ";"; cm["ld"] = ""
}
FNR == 1 {
  n = split(FILENAME, p, "/"); base = p[n]
  if (base ~ /\./ && base !~ /^\./ ) { sub(/.*\./, "", base); ext = tolower(base) }
  else ext = tolower(p[n])
  if (ext == "cmakelists.txt") ext = "cmake"
  files[ext]++
}
{
  total[ext]++
  line = $0; sub(/^[ \t\r]+/, "", line)
  l = tolower(line)
  if (l == "") blank[ext]++
  else if ((cm[ext] != "" && index(l, cm[ext]) == 1) ||
           (cm2[ext] != "" && index(l, cm2[ext]) == 1)) comment[ext]++
  else code[ext]++
}
END {
  for (e in total)
    printf "%s|%d|%d|%d|%d|%d\n", e, files[e], total[e], blank[e], comment[e], code[e]
}' |
awk -F'|' '
{ f[$1]+=$2; t[$1]+=$3; b[$1]+=$4; c[$1]+=$5; k[$1]+=$6 }
END {
  line = "--------------------------------------------------------------------"
  printf "%-12s %8s %10s %10s %10s %10s\n", "Type", "Files", "Total", "Blank", "Comment", "Code"
  print line
  fflush()
  sortcmd = "sort -k6,6nr"
  for (e in t) {
    printf "%-12s %8d %10d %10d %10d %10d\n", e, f[e], t[e], b[e], c[e], k[e] | sortcmd
    TF += f[e]; TT += t[e]; TB += b[e]; TC += c[e]; TK += k[e]
  }
  close(sortcmd)
  print line
  printf "%-12s %8d %10d %10d %10d %10d\n", "TOTAL", TF, TT, TB, TC, TK
}'
