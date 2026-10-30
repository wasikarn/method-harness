#!/usr/bin/env bash
# tmp-delete.sh -- source it to get tmp_delete <path>...: the permanent delete of a test's or
# script's own temp paths through tmp_delete.py next to this file (refuses anything outside a
# temp root; GH #724). python3 is captured now, at source time, because some tests later put a
# python3 stub first on PATH, which would otherwise skip the cleanup and leak (GH #729).
_TMP_DELETE_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TMP_DELETE_PY="$(command -v python3)"
tmp_delete() { "${_TMP_DELETE_PY:?tmp-delete.sh: python3 was not on PATH when this file was sourced}" "$_TMP_DELETE_LIB/tmp_delete.py" "$@"; }
