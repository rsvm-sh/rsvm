#!/usr/bin/env bash
# bash_completion — tab completion for rsvm
# Loaded automatically by rsvm.sh when sourced

_rsvm_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="install i uninstall use current which list ls list-remote ls-remote alias unalias run unload help --version"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return
  fi

  local versions=""
  if [[ -d "${RSVM_DIR:-$HOME/.rsvm}/versions" ]]; then
    versions=$(ls "${RSVM_DIR:-$HOME/.rsvm}/versions" 2>/dev/null)
  fi

  case "$prev" in
    install|i)
      COMPREPLY=( $(compgen -W "--default --save --alias default stable beta nightly $versions" -- "$cur") )
      ;;
    use|uninstall|which|run)
      local aliases="default stable beta nightly system"
      COMPREPLY=( $(compgen -W "$versions $aliases" -- "$cur") )
      ;;
    alias|unalias)
      local alias_names=""
      if [[ -d "${RSVM_DIR:-$HOME/.rsvm}/alias" ]]; then
        alias_names=$(ls "${RSVM_DIR:-$HOME/.rsvm}/alias" 2>/dev/null)
      fi
      COMPREPLY=( $(compgen -W "$alias_names" -- "$cur") )
      ;;
    list-remote|ls-remote)
      COMPREPLY=( $(compgen -W "10 20 50 100" -- "$cur") )
      ;;
  esac
}

complete -F _rsvm_completion rsvm
