#!/usr/bin/env zsh

# TODO: save pipeline to file? (using fzftool, appending to previous pipeline?)
local FZFTOOL_SRC="${FZFTOOL_SRC:-~/.oh-my-zsh/custom/fzftool.zsh}"
typeset -gx FZFREPL_DIR="${FZFREPL_DIR:-${HOME}/.fzfrepl}"
typeset -gx FZFREPL_DATADIR="${FZFREPL_DATADIR:-${TMPDIR:-/tmp}}"
# Check directories (fzf will check FZFREPL_HISTORY & FZFTOOL_SRC, and FZFREPL_COMMANDS is checked later)
if [[ ! -d "${FZFREPL_DATADIR}" ]]; then
    mkdir "${FZFREPL_DATADIR}" || { print "Error: cannot create directory ${FZFREPL_DATADIR}" && return 1 }
fi
if [[ ! -w "${FZFREPL_DATADIR}" ]]; then
    print "Error: cannot write files to ${FZFREPL_DATADIR}"
    return 1
fi

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

Three different selection menus are available via keybindings alt-1/2/3, which can be
altered by setting the FZFREPL_MENU1/2/3 variables. By default menu 1 contains history
for this command, menu 2 contains saved commands, and menu 3 contains queries extracted
from shell history (see the Readme file for more info). FZFREPL_MENU1 is loaded on startup.
Pressing ctrl-s will save a query to $FZFREPL_MENU2 (reload it to see the saved query).
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
local tmpfile2="${FZFREPL_DATADIR}/fzfrepl_shellhist"
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

local cmdword="${${(s: :)${cmd#sudo }}[1]}"
# Files for storing the output, and the command line which creates that output
local tmpfile3="${FZFREPL_DATADIR}/fzfrepl-$$-${cmdword}.out"
local tmpfile4="${FZFREPL_DATADIR}/fzfrepl-$$-${cmdword}.cmd"
touch "${tmpfile4}"
chmod +x "${tmpfile4}"

typeset cmdinput cmdinstr
if [[ ${cmd} != *\{s\}* || ${filebrace} == n ]]; then
    # if the first source is a file we will send all sources to STDIN
    if [[ -f ${(Q)sources[1]} ]]; then
	cmd="${cmd}"
	cmdinput="${sources[@]/#/<}"
	# if its the only source, and is another fzfrepl file, then we
	# are in an fzfrepl pipe, so save it to input pipe
	if [[ ${#sources} == 1 && ${sources[1]} == ?${FZFREPL_DATADIR}/fzfrepl*.out? ]]; then
	    #TODO: debug this, it should save the previous command in the pipe, into the current commands file
	    # but it doesn't currently work because ${sources[1]} is quoted
	    cat ${${${sources[1]##\"}%%\"}//out/cmd} >> "${tmpfile4}"
	    print -n ' | ' >> "${tmpfile4}"
	else
	    cmdinstr="${(q)cmdinput}"
	fi
    else
	# otherwise they are treated as args for the command
	cmd="${cmd} ${sources[@]}"
    fi
else
    if [[ -n ${sources} ]]; then
	cmd="${cmd//\{s\}/${${@/%/\\\"}[@]/#/\\\"}}"
    else
	print "Error: no sources to replace {s} in command string. Did you forget to use the -N option?"
    fi
fi

# optionally display source info in preview window
typeset previewcmd src
if [[ $showhdr == y && -n ${sources[@]} ]]; then
    previewcmd="echo '"
    foreach src (${sources[@]}) {
	# (Q) flags are needed in ALL following lines to work with both quoted and unquoted filenames
	src="${(Q)src}"
	if [[ -f "${(Q)src}" ]]; then
	    previewcmd+="$(basename ${(Q)src})"
	    if [[ -r "${(Q)src}" ]]; then
		previewcmd+="$(stat -c '(%s bytes)' ${(Q)src})"
	    fi
	    previewcmd+="\n"
	else
	    previewcmd+="${src}\n"
	fi
    }
    # this assumes preview window is half the width of the screen
    previewcmd+="${(l:((COLUMNS/2))::=:)}' && "
fi
# optionally limit preview to head of file
if [[ -n ${numlines} && -n ${cmdinput[@]} ]]; then
	previewcmd+="{ head -n ${numlines} ${cmdinput[@]} | eval ${cmd} }"
else
    previewcmd+="eval ${cmd} ${cmdinput}"
fi

: ${helpcmd1:=${cmdword} --help}
: ${helpcmd2:=man ${cmdword}}
: ${FZFREPL_HISTORY:=${FZFREPL_DIR}/${cmdword}_history}
: ${FZFREPL_COMMANDS:=${FZFREPL_DIR}/${cmdword}_commands}
if [[ ! -e ${FZFREPL_HISTORY} ]]; then
    touch ${FZFREPL_HISTORY}
fi
if [[ ! -e ${FZFREPL_COMMANDS} ]]; then
    touch ${FZFREPL_COMMANDS}
fi
# save items from zsh history for history selections (alt-1)
HISTSIZE=10000
fc -R ~/.zsh_history
if [[ -n "${removerx}" ]]; then
    fc -l 1 | grep -o "\<${cmdword} .*" | grep -v "${removerx}" | sort -u | cut -d" " -f 1 --complement > "${tmpfile2}"
else
    fc -l 1 | grep -o "\<${cmdword} .*" | sort -u | cut -d" " -f 1 --complement > "${tmpfile2}"
fi
# menu files which will be loaded when alt-1/2/3 is pressed
typeset -gx FZFREPL_MENU1="${FZFREPL_MENU1:-${FZFREPL_COMMANDS}}"
typeset -gx FZFREPL_MENU2="${FZFREPL_MENU2:-${FZFREPL_HISTORY}}"
typeset -gx FZFREPL_MENU3="${FZFREPL_MENU3:-${tmpfile2}}"
# menu file where items will be saved when ctrl-s is pressed:
typeset -gx FZFREPL_SAVE_MENU="${FZFREPL_SAVE_MENU:-${FZFREPL_MENU1}}"
if [[ -r ${FZFREPL_MENU1} ]]; then
    FZF_DEFAULT_OPTS+=" --bind 'alt-1:reload(cat ${FZFREPL_MENU1})'"
else
    print "Warning: unable to read commands from ${FZFREPL_MENU1}"
fi
if [[ -r ${FZFREPL_MENU2} ]]; then
    FZF_DEFAULT_OPTS+=" --bind 'alt-2:reload(cat ${FZFREPL_MENU2})'"
else
    print "Warning: unable to read commands from ${FZFREPL_MENU2}"
fi
if [[ -r ${FZFREPL_MENU3} ]]; then
    FZF_DEFAULT_OPTS+=" --bind 'alt-3:reload(cat ${FZFREPL_MENU3})'"
else
    print "Warning: unable to read commands from ${FZFREPL_MENU3}"
fi
if [[ -w ${FZFREPL_SAVE_MENU} ]]; then
    FZF_DEFAULT_OPTS+=" --bind 'ctrl-s:execute-silent(if ! grep -Fqs {q} ${FZFREPL_SAVE_MENU};then echo {q} >> ${FZFREPL_SAVE_MENU};fi)'"
else
    print "Warning: unable to save commands to ${FZFREPL_SAVE_MENU}"
fi

local prompt="($$)${${cmd//\{q\}}:0:15} ${${${${cmd//\{q\}}:15}:-}:+... }"
# Fit header to fit screen
local header1="${colors[green]}${FZFREPL_HEADER:-C-g:quit|C-j:finish|C-t:toggle preview window|RET:copy selection to prompt|M-w:copy prompt to clipboard|C-v:view input|M-v:view output|M-1/2/3:change selections|M-h:show help|C-h:show more help}${colors[reset]}"
if [[ -a "${FZFTOOL_SRC}" ]]; then
    header1="${header1//view output|/view output|alt-j/k:pipe output to another tool and stay open/quit|}"
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
    FZF_DEFAULT_OPTS+=" --bind 'alt-j:execute(eval ${cmd} ${cmdinput} > ${tmpfile3}; print -n ${cmd} ${cmdinstr} >> ${tmpfile4}; source ${FZFTOOL_SRC} && fzftoolmenu ${tmpfile3})'"
    # as above but also quit current session
    FZF_DEFAULT_OPTS+=" --bind 'alt-k:execute(eval ${cmd} ${cmdinput} > ${tmpfile3}; print -n ${cmd} ${cmdinstr} >> ${tmpfile4}; source ${FZFTOOL_SRC} && fzftoolmenu ${tmpfile3})+abort'"
fi

FZF_DEFAULT_OPTS+=" --bind 'enter:replace-query,ctrl-j:accept,ctrl-t:toggle-preview,ctrl-k:kill-line,home:top'"
FZF_DEFAULT_OPTS+=" --bind 'alt-h:execute(eval $helpcmd1|${PAGER} >/dev/tty)'"
FZF_DEFAULT_OPTS+=" --bind 'ctrl-h:execute(eval $helpcmd2|${PAGER} >/dev/tty)'"
FZF_DEFAULT_OPTS+=" --bind 'ctrl-v:execute(${PAGER} ${cmdinput:-${sources[@]}} >/dev/tty)'"
FZF_DEFAULT_OPTS+=" --bind 'alt-v:execute(eval ${cmd} ${cmdinput}|${PAGER} >/dev/tty)'"
FZF_DEFAULT_OPTS+=" --bind 'alt-w:execute-silent(echo ${cmd}|xclip -selection clipboard)'"
FZF_DEFAULT_OPTS+=" --preview-window=right:50% --height=100% --prompt '${prompt}'"
FZF_DEFAULT_OPTS+=" ${FZFREPL_DEFAULT_OPTS}"

local -a qry
IFS="
"

qry=($(cat "${FZFREPL_MENU1}" |\
	   fzf --query="${default_query}" --sync --ansi --print-query \
	       ${FZFREPL_HISTORY:+--history=$FZFREPL_HISTORY} \
	       --preview="${previewcmd}"))

if [[ -z ${qry} ]]; then
    exit
fi
if [[ ${output} =~ [oO] ]]; then
    eval "${cmd//\{q\}/${qry[1]}} ${cmdinput}"
elif [[ ${output} =~ [qQ] ]]; then
    print - "${(Q)qry[1]}"
else
    print - "${cmdword} ${cmd//\{q\}/${qry[1]}} ${cmdinput}"
fi
# Save command to file
print - "${cmd//\{q\}/${qry[1]}} ${cmdinstr}" >> "${tmpfile4}"
# Delete files no longer needed
if [[ -e ${tmpfile1} ]]; then
   rm ${tmpfile1}
fi
if [[ -e ${tmpfile2} ]]; then
   rm ${tmpfile2}
fi
