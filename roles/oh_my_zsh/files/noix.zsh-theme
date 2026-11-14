# noix theme: user@host, working directory, git branch with a dirty mark, the
# last exit status when it is not zero, and # for root or % otherwise.
# The host is in color 38 (#00afd7), the xterm-256 color nearest to the noix
# cyan #00B8C8. On root the host is red and the user part is left out.
if [[ $EUID -eq 0 ]]; then
  _noix_who='%B%F{red}%m%f%b'
else
  _noix_who='%n@%B%F{38}%m%f%b'
fi

ZSH_THEME_GIT_PROMPT_PREFIX='%F{yellow}('
ZSH_THEME_GIT_PROMPT_SUFFIX=')%f '
ZSH_THEME_GIT_PROMPT_DIRTY='*'
ZSH_THEME_GIT_PROMPT_CLEAN=''

PROMPT='${_noix_who} %F{blue}%~%f $(git_prompt_info)%(?..%F{red}[%?]%f )%(!.#.%%) '
