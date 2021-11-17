#!/usr/bin/env zsh

# TODO: save pipeline to file? (using fzftool, appending to previous pipeline?)
#       save pipeline to top of file? or separate file labelled by PID? (fzfrepl-$$.cmd?)
local FZFTOOL_SRC="${FZFTOOL_SRC:-~/.oh-my-zsh/custom/fzftool.zsh}"
local FZFREPL_DIR="${FZFREPL_DIR:-${HOME}/.fzfrepl}"
local TMPDIR="${TMPDIR:-/tmp}"
local FZFREPL_DATADIR="${FZFREPL_DATADIR:-${TMPDIR}}"
# Check files & directories (fzf will check FZFREPL_HISTORY & FZFTOOL_SRC, and FZFREPL_COMMANDS is checked later)
if [[ ! ( -d "${TMPDIR}" && -w "${TMPDIR}" ) ]]; then
    print "Error: cannot write files to TMPDIR=${TMPDIR}"
    return 1
fi
if [[ ! -d "${FZFREPL_DATADIR}" ]]; then
    mkdir "${FZFREPL_DATADIR}" || { print "Error: cannot create directory ${FZFREPL_DATADIR}" && return 1 }
fi
if [[ ! -w "${FZFREPL_DATADIR}" ]]; then
    print "Error: cannot write files to ${FZFREPL_DATADIR}"
    return 1
fi
# TODO: replace FILE with SOURCE
usage() {
  less -FEXR <<'HELP'
fzfrepl -c "CMD {q}" [OPTION]... [SOURCE]...
Interactively view output from CMD (e.g. a stream filter like awk or sed) while editing args using fzf.
Each SOURCE may be a filename, URL or other input source argument to CMD.
If no SOURCE is supplied, STDIN is used (unless the -i option is present).
OPTIONS:
  -c, --cmd CMDSTR        command string to filter input ({q} & {s} are replaced by query string & SOURCEs)
  -q, --query QUERY       default query string to use (i.e. initial prompt input)
  -o, --output [o|q]      output the command output (o) or just the query string (q)
                          (by default the command with embedded query string is output)
  -H1, --helpcmd1 CMDSTR  command for displaying help when alt-h is pressed (default: "CMD --help")
  -H2, --helpcmd2 CMDSTR  command for displaying more help when ctrl-h is pressed (default: "man CMD")
  -r, --remove REGEX      regexp for filtering out shell history items (e.g. '-i' for sed)
  -d, --header            show filename, size & permissions at top of preview window
  -n, --numlines N        No. of lines piped to preview command (all by default). Useful for large files.
  -N, --no-src-subst      don't replace {s} with SOURCEs
  -i, --ignore-stdin	  ignore any input from STDIN (STDIN is also ignored if there are SOURCE args)
  -h, --help              show this help text

By default fzfrepl history is saved to ~/.fzfrepl/CMD_history (when CMD is the main command word),
and its contents are available for selection in the main screen, or by pressing alt-1.
You can switch to the contents of ~/.fzfrepl/CMD_commands by pressing alt-2, or to filtered 
zsh shell history (lines matching CMD but not the -r option arg) by pressing alt-3.
To change the location of these files set FZFREPL_HISTORY & FZFREPL_COMMANDS, or just FZFREPL_DIR.

To alter fzf options set FZFREPL_DEFAULT_OPTS, e.g. FZFREPL_DEFAULT_OPTS="--preview-window=down:50%"

examples:
  echo 'foo bar' | fzfrepl -o o -c 'awk {q}' -q '{print}'
  echo 'hello world' | fzfrepl -o o -q p 'sed -n {q}'
  fzfrepl -c 'grep {q} {s}' /path/to/files/*.txt
  fzfrepl -o o -c 'sqlite3 -csv {s} {q}' mydatabase.db | mlr -o -c 'mlr {q}' -q '--csv stats2'
  seq 5 | awk '{print 2*$1,$1*$1}' | fzfrepl -c "feedgnuplot --terminal \\\"dumb ${COLUMNS},${LINES}\\\" --exit {q}"
HELP
}

# TODO: better "wrapping", this is painful:
# fzfrepl 'node -e {q}' -q "done = data => data;\nlet A='';process.stdin.on('data',x=>A=A.concat(x.toString())).on('end',()=>{let d = done(A);process.stdout.write(`${String.prototype.trim.call(typeof d==='string'?d:JSON.stringify(d,null,2))}\n`)})"

local tmpfile1="${FZFREPL_DATADIR}/fzfrepl-$$.in"
local tmpfile2="${TMPDIR}/fzfrepl-shellhist"
local tmpfile3="${FZFREPL_DATADIR}/fzfrepl-$$.out"
local cmd default_query output helpcmd1 removerx 
local filebrace numlines showhdr ignorestdin

typeset -A colors
colors[red]=$(tput setaf 1)
colors[green]=$(tput setaf 2)
colors[reset]=$(tput sgr0)

cleanup() {
    [[ -e "${tmpfile1}" ]] && rm "${tmpfile1}"
    [[ -e "${tmpfile2}" ]] && rm "${tmpfile2}"
    # TODO: do I really want to delete output?
    [[ -e "${tmpfile3}" ]] && rm "${tmpfile3}"
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
	    output="$2"
	    shift 2
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
	-N|--no-src-subst)
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

# non-option args are treated as input sources
typeset -a sources
# If there are no sources use STDIN
if [[ -n "${@}" ]]; then
    # quote source names in case they contain spaces
    sources=(${${@/%/\"}[@]/#/\"})
elif [[ ${ignorestdin} != y ]]; then
    cat > ${tmpfile1}
    sources=(${tmpfile1})
fi

typeset cmdinput 
if [[ ${cmd} != *\{s\}* || ${filebrace} == n ]]; then
    # if the first source is a file we will send all sources to STDIN
    if [[ -f ${sources[1]} ]]; then
	cmd="${cmd}"
	cmdinput="${sources[@]/#/<}"
    else
	# otherwise they are treated as args for the command
	cmd="${cmd} ${sources[@]}"
    fi
else
    if [[ -n ${sources} ]]; then
	cmd="${cmd//\{s\}/${sources[@]}}"
    else
	print "Error: no sources to replace {s} in command string. Did you forget to use the -N option?"
    fi
fi
# optionally display source info in preview window
typeset previewcmd src
if [[ $showhdr == y && -n ${sources[@]} ]]; then
    previewcmd="echo 'SOURCES: "
    foreach src (${sources[@]}) {
	src=${src//\"}
	if [[ -f ${src} ]]; then
	    previewcmd+="$(basename ${src})"
	    if [[ -r ${src} ]]; then
		previewcmd+="$(stat -c '(%s bytes)' ${src})"
	    fi
	    previewcmd+=", "
	else
	    previewcmd+="${src}, "
	fi
    }
    previewcmd+="' && echo && "
fi
# optionally limit preview to head of file
if [[ -n ${numlines} && -n ${cmdinput[@]} ]]; then
	previewcmd+="{ head -n ${numlines} ${cmdinput[@]} | eval ${cmd} }"
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
if [[ ! -e ${FZFREPL_COMMANDS} ]]; then
    touch ${FZFREPL_COMMANDS}
else
    if [[ -r ${FZFREPL_COMMANDS} ]]; then
	FZF_DEFAULT_OPTS+=" --bind 'alt-2:reload(cat ${FZFREPL_COMMANDS})'"
    else
	print "Warning: unable to read commands from ${FZFREPL_COMMANDS}"
    fi
    if [[ -w ${FZFREPL_COMMANDS} ]]; then
	FZF_DEFAULT_OPTS+=" --bind 'ctrl-s:execute-silent(if ! grep -Fqs {q} ${FZFREPL_COMMANDS};then echo {q} >> ${FZFREPL_COMMANDS};fi)'"
    else
	print "Warning: unable to save commands to ${FZFREPL_COMMANDS}"
    fi
fi
# save items from zsh history for history selections (alt-1)
HISTSIZE=10000
fc -R ~/.zsh_history
if [[ -n "${removerx}" ]]; then
    fc -l 1 | grep -o "\<${cmdword} .*" | grep -v "${removerx}" | sort -u | cut -d" " -f 1 --complement > "${tmpfile2}"
else
    fc -l 1 | grep -o "\<${cmdword} .*" | sort -u | cut -d" " -f 1 --complement > "${tmpfile2}"
fi

local prompt="($$)${${cmd//\{q\}}:0:15} ${${${${cmd//\{q\}}:15}:-}:+... }"
# Fit header to fit screen
local header1="${colors[green]}${FZFREPL_HEADER:-C-g:quit|C-j:finish|C-t:toggle preview window|RET:copy selection to prompt|M-w:copy prompt to clipboard|C-v:view input|M-v:view output|M-1/2/3:change selections|M-h:show help|C-h:show more help}${colors[reset]}"
if [[ -a "${FZFTOOL_SRC}" ]]; then
    header1="${header1//view output|/view output|alt-j:pipe output to another tool|}"
fi
local header2 i1=0 ncols=$((COLUMNS-5))
local i2=${ncols}
until ((i2>${#header1})); do
    i2=${${header1[${i1:-0},${i2}]}[(I)\|]}
    header2+="${header1[${i1},((i1+i2-1))]}
"
    i1=$((i1+i2+1))
    i2=$((i1+ncols))
done
header2+=${header1[$i1,$i2]}

FZF_DEFAULT_OPTS+=" --header='${header2}'"
# Add keybinding for continuing the pipeline with fzftoolmenu, if available
if [[ -a ${FZFTOOL_SRC} ]]; then
    # continue to fzftoolmenu even with non-zero exit status after saving output to ${tmpfile3}
    FZF_DEFAULT_OPTS+=" --bind 'alt-j:execute(eval ${cmd} ${cmdinput} > ${tmpfile3}; source ${FZFTOOL_SRC} && fzftoolmenu ${tmpfile3})'"
    #TODO: have another keybinding the same as above but with +abort appended?
fi
FZF_DEFAULT_OPTS+=" --bind 'enter:replace-query,ctrl-j:accept,ctrl-t:toggle-preview,ctrl-k:kill-line,home:top'"
FZF_DEFAULT_OPTS+=" --bind 'alt-h:execute(eval $helpcmd1|${PAGER} >/dev/tty)'"
FZF_DEFAULT_OPTS+=" --bind 'ctrl-h:execute(eval $helpcmd2|${PAGER} >/dev/tty)'"
FZF_DEFAULT_OPTS+=" --bind 'ctrl-v:execute(${PAGER} ${cmdinput:-${sources[@]}} >/dev/tty)'"
# following command is quoted differently to work with URLs containing spaces
FZF_DEFAULT_OPTS+=" --bind \"alt-v:execute(eval '${(q)cmd} ${(q)cmdinput}' | ${PAGER} >/dev/tty)\""
FZF_DEFAULT_OPTS+=" --bind 'alt-w:execute-silent(echo ${cmd}|xclip -selection clipboard)'"
FZF_DEFAULT_OPTS+=" --bind 'alt-1:reload(cat ${FZFREPL_HISTORY}),alt-3:reload(cat ${tmpfile2})'"
FZF_DEFAULT_OPTS+=" --preview-window=right:50% --height=100% --prompt '${prompt}'"
FZF_DEFAULT_OPTS+=" ${FZFREPL_DEFAULT_OPTS}"

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
if [[ ${output} =~ [oO] ]]; then
    eval "${cmd//\{q\}/${qry[1]}} ${cmdinput}"
elif [[ ${output} =~ [qQ] ]]; then
    echo "${(Q)qry[1]}"
else
    echo "${cmd//\{q\}/${qry[1]}}"
fi

if [[ -e ${tmpfile1} ]]; then
   rm ${tmpfile1}
fi
if [[ -e ${tmpfile2} ]]; then
   rm ${tmpfile2}
fi
