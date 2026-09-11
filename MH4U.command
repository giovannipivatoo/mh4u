#!/bin/zsh
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
cd -- "${0:A:h}" || exit 1
exec python3 tools/mh4u.py run
