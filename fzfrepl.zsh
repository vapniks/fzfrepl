#!/usr/bin/env zsh

local FZFREPL_DIR="${FZFREPL_DIR:-${HOME}/.fzfrepl}"

usage() {
  less -FEXR <<'HELP'
fzfrepl -c "CMD" [OPTION]... [FILE]...
Interactively edit stdin using stream filters like awk, sed, jq, mlr. Uses STDIN if no FILE is supplied.
OPTIONS:
  -c, --cmd CMDSTR        command string to filter input ({q} & {f} are replaced by query string & FILE)
  -q, --query QUERY       default query string to use (i.e. initial prompt input)
  -o, --output            output the stream filter (otherwise just the command is printed)
  -H1, --helpcmd1 CMDSTR  command for displaying help when alt-h is pressed (default: "CMD --help")
  -H2, --helpcmd2 CMDSTR  command for displaying more help when ctrl-h is pressed (default: "man CMD")
  -r, --remove REGEX      regexp for filtering out shell history items (e.g. '-i' for sed)
  -d, --header            show filename, size & permissions at top of preview window
  -n, --numlines N        No. of lines piped to preview command (all by default). Useful for large files.
  -N, --no-file-subst     don't replace {f} with FILE(s)
  -i, --ignore-stdin	  ignore any input from STDIN (STDIN is also ignored if there are FILE args)
  -h, --help              show this help text

By default fzfrepl history is saved to ~/.fzfrepl/CMD_history (when CMD is the main command word),
and its contents are available for selection in the main screen, or by pressing alt-1.
You can switch to the contents of ~/.fzfrepl/CMD_commands by pressing alt-2, or to filtered 
zsh shell history (lines matching CMD but not the -r option arg) by pressing alt-3.
To change the location of these files set FZFREPL_HISTORY & FZFREPL_COMMANDS, or just FZFREPL_DIR.

To alter fzf options set FZFREPL_DEFAULT_OPTS, e.g. FZFREPL_DEFAULT_OPTS="--preview-window=down:50%"

examples:
  echo 'foo bar' | fzfrepl -o -c 'awk {q}' -q '{print}'
  echo 'hello world' | fzfrepl -o -q p 'sed -n {q}'
  fzfrepl -c 'grep {q} {f}' /path/to/files/*.txt
  fzfrepl -o -c 'sqlite3 -csv {f} {q}' mydatabase.db | mlr -o -c 'mlr {q}' -q '--csv stats2'
  seq 5 | awk '{print 2*$1,$1*$1}' | fzfrepl -c "feedgnuplot --terminal \\\"dumb ${COLUMNS},${LINES}\\\" --exit {q}"
HELP
}

# TODO: better "wrapping", this is painful:
# fzfrepl 'node -e {q}' -q "done = data => data;\nlet A='';process.stdin.on('data',x=>A=A.concat(x.toString())).on('end',()=>{let d = done(A);process.stdout.write(`${String.prototype.trim.call(typeof d==='string'?d:JSON.stringify(d,null,2))}\n`)})"

local tmpfile1="/tmp/fzfreplinput$$"
local tmpfile2=/tmp/fzfreplshellhist
local cmd default_query output helpcmd1 removerx 
local filebrace numlines showhdr ignorestdin

typeset -A colors
colors[red]=$(tput setaf 1)
colors[green]=$(tput setaf 2)
colors[reset]=$(tput sgr0)

cleanup() {
    [[ -e "${tmpfile1}" ]] && rm "${tmpfile1}"
    [[ -e "${tmpfile2}" ]] && rm "${tmpfile2}"
}
trap cleanup SIGHUP SIGINT SIGTERM

color() {
  local color
  color="$1"; shift
  printf '%s' "${colors[$color]}" "$*" "${colors[reset]}"
}

err() {
  color red "$@" >&2
  return 1
}

die() {
    (( $# > 0 )) && err "$@"
    exit 1
}

for arg; do
    case $1 in
	-q|--query)
	    [[ -z $2 || $2 = -* ]] && die "missing argument to $1"
	    default_query="$2"
	    shift 2
	    ;;
	-c|--cmd)
	    [[ -z $2 || $2 = -* ]] && die "missing argument to $1"
	    cmd="$2"
	    shift 2
	    ;;
	-o|--output)
	    output=y
	    shift 1
	    ;;
	-H1|--helpcmd1)
	    helpcmd1="$2"
	    shift 2
	    ;;
	-H2|--helpcmd2)
	    helpcmd2="$2"
	    shift 2
	    ;;
	-r|--remove)
	    removerx="$2"
	    shift 2
	    ;;
	-n|--numlines)
	    numlines="$2"
	    shift 2
	    ;;
	-d|--header)
	    showhdr=y
	    shift 1;
	    ;;
	-N|--no-file-substitution)
	    filebrace=n
	    shift 1;
	    ;;
	-i|--ignore-stdin)
	    ignorestdin=y
	    shift 1;
	    ;;
	-h|--help) usage; exit ;;
	*)  break 2
	    ;;
    esac
done

if [[ -z $cmd && -n $1 && ! -f $1 ]]; then
  cmd="$1"
  shift
fi

if [[ -z $cmd ]]; then
  usage
  exit 1
fi

if [[ $cmd != *'{q}'* ]]; then
  cmd+=' {q}'
fi

local file files
if [[ -n $1 && -f $1 ]]; then
    file=$1
    files=$@
fi

if [[ -z ${file} && ${ignorestdin} != y ]]; then
    cat > ${tmpfile1}
fi

local previewcmd cmdinput
if [[ ${cmd} =~ '\{f\}' && ${filebrace} != n && -n ${files} ]]; then
    cmd="${cmd//\{f\}/${files[@]}}"
elif [[ -n ${file} || -s ${tmpfile1} ]]; then
    cmdinput="<${(q)file:-${tmpfile1}}"
fi
if [[ $showhdr == y ]]; then
   previewcmd="echo 'NAME = ${file}' && stat -c 'SIZE = %s, PERMISSIONS = %U:%G:%A' ${file} && echo && "
fi
if [[ -n ${numlines} && ( -n ${file} || -s ${tmpfile1} ) ]]; then
    if [[ -n ${file} ]]; then
	previewcmd+="{ head -n ${numlines} ${file} | eval ${cmd} }"
    else
	previewcmd+="{ head -n ${numlines} ${tmpfile1} | eval ${cmd} }"
    fi
else
    previewcmd+="eval ${cmd} ${cmdinput}"
fi

local cmdword="${${(s: :)${cmd#sudo }}[1]}"
: ${helpcmd1:=${cmdword} --help}
: ${helpcmd2:=man ${cmdword}}
: ${FZFREPL_HISTORY:=${FZFREPL_DIR}/${cmdword}_history}
: ${FZFREPL_COMMANDS:=${FZFREPL_DIR}/${cmdword}_commands}

if [[ ! -e ${FZFREPL_HISTORY} ]]; then
    touch ${FZFREPL_HISTORY}
fi

HISTSIZE=10000
fc -R ~/.zsh_history
if [[ -n "${removerx}" ]]; then
    fc -l -1 | grep -o "\<${cmdword} .*" | grep -v "${removerx}" | \
	cut -d" " -f 1 --complement > "${tmpfile2}"
else
    fc -l -1 | grep -o "\<${cmdword} .*" | \
	cut -d" " -f 1 --complement > "${tmpfile2}"
fi

local prompt="${${cmd//\{q\}}:0:15} ${${${${cmd//\{q\}}:15}:-}:+... }"

# Fix header to fit screen
local header1="${colors[green]}${FZFREPL_HEADER:-C-g=quit:C-j=finish:C-t=toggle preview window:RET=copy selection to prompt:M-w=copy prompt to clipboard:C-v=view input:M-v=view output:M-1/2/3=change selections:M-h=show help:C-h=show more help}${colors[reset]}"
local header2 i1=0 i2=0 ncols=$((COLUMNS-5))
until ((i2>${#header1})); do
    i2=${${header1[${i1:-0},((i1+ncols))]}[(I):]}
    header2+="${header1[$i1,((i2-1))]}
"
    i1=$((i2+1))
    i2=$((i2+ncols))
done
header2+=${header1[$i1,$i2]}

FZF_DEFAULT_OPTS+=" --header='${header2//:/,}'"
FZF_DEFAULT_OPTS+=" --bind 'ctrl-s:execute-silent({ if ! [ -e ${FZFREPL_COMMANDS} ]; then touch ${FZFREPL_COMMANDS}; fi } && { if ! grep -Fqs {q} ${FZFREPL_COMMANDS};then echo {q} >> ${FZFREPL_COMMANDS};fi })'"
FZF_DEFAULT_OPTS+=" --bind 'enter:replace-query,ctrl-j:accept,ctrl-t:toggle-preview,ctrl-k:kill-line,home:top,alt-1:reload(cat ${FZFREPL_HISTORY}),alt-2:reload(cat ${FZFREPL_COMMANDS}),alt-3:reload(cat ${tmpfile2}),alt-h:execute(eval $helpcmd1|${PAGER} >/dev/tty),ctrl-h:execute(eval $helpcmd2|${PAGER} >/dev/tty),ctrl-v:execute(${PAGER} ${cmdinput:-${files[@]}} >/dev/tty),alt-v:execute(eval ${cmd} ${cmdinput} | ${PAGER} >/dev/tty),alt-w:execute-silent(echo ${cmd}|xclip -selection clipboard)' --preview-window=right:50% --height=100% --prompt '${prompt}' ${FZFREPL_DEFAULT_OPTS}"

local -a qry
IFS="
"

qry=($(cat "${FZFREPL_HISTORY}" |\
	   fzf --query="$default_query" --sync --ansi --print-query \
	       ${FZFREPL_HISTORY:+--history=$FZFREPL_HISTORY} \
	       --preview="${previewcmd}"))

if [[ -z ${qry} ]]; then
    exit
fi
if [[ -n ${output} ]]; then
    eval "${cmd//\{q\}/${qry[1]}} ${cmdinput}"
else
    echo "${cmd//\{q\}/${qry[1]}}"
fi

if [[ -e ${tmpfile1} ]]; then
   rm ${tmpfile1}
fi
