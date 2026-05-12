module output
module helper
module functions

VERSION='1.0.0'

readonly VERSION

usage () {
  cat <<EOF
Podman Bench for Security - Podman, Inc. (c) 2015-$(date +"%Y")
Checks for dozens of common best-practices around deploying Podman containers in production.
Based on the CIS Podman Benchmark 1.3.1.

Usage: podman-security-bench.sh [OPTIONS]

Example:
  - Only run check "2.2 - Ensure the logging level is set to 'info'":
      bash podman-security-bench.sh -c check_2_2
  - Run all available checks except the host_configuration group and "2.8 - Enable user namespace support":
      bash podman-security-bench.sh -e host_configuration,check_2_8
  - Run just the container_images checks except "4.5 - Ensure Content trust for Podman is Enabled":
      bash podman-security-bench.sh -c container_images -e check_4_5

Options:
  -b           optional  Do not print colors
  -h           optional  Print this help message
  -l FILE      optional  Log output in FILE, inside container if run using podman
  -c CHECK     optional  Comma delimited list of specific check(s) id
  -e CHECK     optional  Comma delimited list of specific check(s) id to exclude
  -i INCLUDE   optional  Comma delimited list of patterns within a container or image name to check
  -x EXCLUDE   optional  Comma delimited list of patterns within a container or image name to exclude from check
  -n LIMIT     optional  In JSON output, when reporting lists of items (containers, images, etc.), limit the number of reported items to LIMIT. Default 0 (no limit).
  -p PRINT     optional  Print remediation measures. Default: Don't print remediation measures.
  -w PATH      optional  Path to directory containing files with allowed content.

Complete list of checks: <https://github.com/containers/podman-security-bench/tree/main/tests>
Full documentation: <https://github.com/containers/podman-security-bench#readme>
Released under the Apache-2.0 License. <https://github.com/containers/podman-security-bench/blob/main/LICENSE.md>
EOF
}

main () {
  local this_path
  local myname
  local lists_path
  local logger
  local limit
  local printremediation
  local nocolor
  local check
  local checkexclude
  local include
  local exclude
  local containers
  local images
  local benchcont
  local benchimagecont
  local totalChecks
  local currentScore
  local globalRemediation

  this_path=$(abspath "$0")
  myname=$(basename "${this_path%.*}")
  lists_path="default-lists"

  export PATH="$PATH:/bin:/sbin:/usr/bin:/usr/local/bin:/usr/sbin/"

  req_programs 'awk podman grep stat tee tail wc xargs truncate sed skopeo jq'

  if ! podman ps -q >/dev/null 2>&1; then
    printf "Error executing podman (does podman ps work?)\n"
    exit 1
  fi

  if [ ! -d log ]; then
    mkdir log
  fi

  logger="log/${myname}.log"
  limit=0
  printremediation="0"
  globalRemediation=""

  while getopts bhl:u:c:e:i:x:t:n:p:w: args
  do
    case $args in
    b) nocolor="nocolor";;
    h) usage; exit 0 ;;
    l) logger="$OPTARG" ;;
    c) check="$OPTARG" ;;
    e) checkexclude="$OPTARG" ;;
    i) include="$OPTARG" ;;
    x) exclude="$OPTARG" ;;
    n) limit="$OPTARG" ;;
    p) printremediation="1" ;;
    w) lists_path="$OPTARG" ;;
    *) usage; exit 1 ;;
    esac
  done

  export LISTS_PATH="$lists_path"

  yell_info
  yell "Path to allow files set to: $(realpath "$LISTS_PATH")"

  if [ "$(id -u)" != "0" ]; then
    warn "$(yell 'Some tests might require root to run')\n"
    sleep 3
  fi

  totalChecks=0
  currentScore=0

  logit "Initializing $(date +%Y-%m-%dT%H:%M:%S%:z)\n"
  beginjson "$VERSION" "$(date +%s)"

  logit "\n${bldylw}Section A - Check results${txtrst}"

  get_podman_configuration_file

  benchcont="nil"
  for c in $(podman ps --quiet); do
    if podman inspect --format '{{ .Config.Labels }}' "$c" | \
     grep -e 'podman.bench.security' >/dev/null 2>&1; then
      benchcont="$c"
    fi
  done

  benchimagecont="nil"
  for c in $(podman images --quiet); do
    if podman inspect --format '{{ .Config.Labels }}' "$c" | \
     grep -e 'podman.bench.security' >/dev/null 2>&1; then
      benchimagecont="$c"
    fi
  done

  if [ -n "$include" ]; then
    local pattern
    pattern=$(echo "$include" | sed 's/,/|/g')
    containers=$(podman ps --quiet | grep -v "$benchcont" | grep -E "$pattern")
    images=$(podman images --noheading | grep -E "$pattern" | awk '{print $3}' | grep -v "$benchimagecont")
  elif [ -n "$exclude" ]; then
    local pattern
    pattern=$(echo "$exclude" | sed 's/,/|/g')
    containers=$(podman ps --quiet | grep -v "$benchcont" | grep -Ev "$pattern")
    images=$(podman images --noheading | grep -Ev "$pattern" | awk '{print $3}' | grep -v "$benchimagecont")
  else
    containers=$(podman ps --quiet | grep -v "$benchcont")
    images=$(podman images --quiet | grep -v "$benchimagecont")
  fi

  for test in tests/*.sh; do
    . ./"$test"
  done

  if [ -z "$check" ] && [ ! "$checkexclude" ]; then
    cis
  elif [ -z "$check" ]; then
    check=$(sed -ne "/cis() {/,/}/{/{/d; /}/d; p}" src/functions.sh)
  fi

  for c in $(echo "$check" | sed "s/,/ /g"); do
    if ! command -v "$c" 2>/dev/null 1>&2; then
      echo "Check \"$c\" doesn't seem to exist."
      continue
    fi
    if [ -z "$checkexclude" ]; then
      "$c"
    else
      local checkexcluded
      checkexcluded="$(echo ",$checkexclude" | sed -e 's/^/\^/g' -e 's/,/\$|/g' -e 's/$/\$/g')"

      if echo "$c" | grep -E "$checkexcluded" 2>/dev/null 1>&2; then
        continue
      elif echo "$c" | grep -vE 'check_[0-9]|check_[a-z]' 2>/dev/null 1>&2; then
        local loop_checks
        loop_checks="$(sed -ne "/$c() {/,/}/{/{/d; /}/d; p}" src/functions.sh)"
      else
        local loop_checks
        loop_checks="$c"
      fi

      for lc in $loop_checks; do
        if echo "$lc" | grep -vE "$checkexcluded" 2>/dev/null 1>&2; then
          "$lc"
        fi
      done
    fi
  done

  if [ -n "${globalRemediation}" ] && [ "$printremediation" = "1" ]; then
    logit "\n\n${bldylw}Section B - Remediation measures${txtrst}"
    logit "${globalRemediation}"
  fi

  logit "\n\n${bldylw}Section C - Score${txtrst}\n"
  info "Checks: $totalChecks"
  info "Score: $currentScore\n"

  endjson "$totalChecks" "$currentScore" "$(date +%s)"
}

main "$@"
