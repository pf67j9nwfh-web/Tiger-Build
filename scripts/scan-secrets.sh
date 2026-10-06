#!/bin/sh
# Refuses to package a tree that contains a key or a private key.   usage: scan-secrets.sh [folder]
ROOT="${1:-.}"
# the patterns are built from pieces so this file does not match itself
A="BEGIN OPENSSH PRIVATE ""KEY"; B="BEGIN RSA PRIVATE ""KEY"; C="BEGIN PRIVATE ""KEY"; D="sk-""ant-"; E="sk-""proj-"; F="xa""i-"; G="AI""za"
bad=$(grep -rIlE --exclude-dir=.git --exclude-dir=dist --exclude-dir=build -e "$A|$B|$C|$D|$E|$F|$G" "$ROOT" 2>/dev/null | grep -v "scan-secrets.sh")
filled=$(grep -rIlE --exclude-dir=.git --exclude-dir=dist --exclude-dir=build -e '^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_]*API_KEY[[:space:]]*=[[:space:]]*["'"'"']?[^"'"'"'[:space:]]{9,}' "$ROOT" 2>/dev/null)
if [ -n "$bad$filled" ]; then
  echo "Refusing to build the installer because it would contain secrets:" >&2
  [ -n "$bad" ] && echo "$bad" | sed 's/$/ matches a secret pattern/' >&2
  [ -n "$filled" ] && echo "$filled" | sed 's/$/ has a filled API key line/' >&2
  exit 1
fi
echo "secret scan ok"
