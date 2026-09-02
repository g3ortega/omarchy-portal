#!/bin/bash
# Owner-only state files. Every state path Portal reads or writes is
# predictable (a port number under a fixed directory), so a file is trusted
# only when it is a plain file the current user owns and not a symlink, reads
# are byte-capped, and writes remove whatever was at the path first so a
# planted link can never redirect them.
own_dir() {   # <dir>: create it 700, then insist it is our own real directory
  install -d -m 700 -- "$1" 2>/dev/null
  [[ -d $1 && ! -L $1 && -O $1 ]]
}
own_file() { [[ -f $1 && ! -L $1 && -O $1 ]]; }
read_own() {  # <file> [maxbytes]: the first line of a plain owned file
  own_file "$1" || return 1
  head -c "${2:-4096}" -- "$1" | head -n 1
}
cat_own() {   # <file> [maxbytes]: the whole file, capped
  own_file "$1" || return 1
  head -c "${2:-1048576}" -- "$1"
}
write_own() { # <file> <content>: replace, never follow
  rm -f -- "$1"
  printf '%s' "$2" > "$1"
}
