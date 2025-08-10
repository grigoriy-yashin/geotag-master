#!/usr/bin/env bash
set -euo pipefail

# Minimal, working geotagger:
# Phase 1: shift times by NET ((to-from) - ahead + behind) and write OffsetTime* if requested
# Phase 2: geotag with -geotime<${DateTimeOriginal}+TZ>; no extra -geosync after Phase 1

PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""    # UTC+3, +03:00, +3, -04:30
TO_TZ=""      # UTC+5, +05:00, etc.
TZ_TAG=""     # +05:00 to write OffsetTime* (optional)

DRIFT_KIND="" # ahead|behind
DRIFT_VAL=""  # 3m|45s|1:30m  (never think about +/-)

COPY_MATCHED=0
OVERWRITE=1
VERBOSE=0
DRYRUN=0
MAX_EXT_SECS=0  # end extension (seconds) for near-out-of-range matches

die(){ echo "Error: $*" >&2; exit 1; }

# ---------- arg parse ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --photos) PHOTOS_ROOT="${2:-}"; shift 2;;
    --pool)   GPX_POOL="${2:-}"; shift 2;;
    --from-tz) FROM_TZ="${2:-}"; shift 2;;
    --to-tz)   TO_TZ="${2:-}"; shift 2;;
    --tz-tag|--set-offset) TZ_TAG="${2:-}"; shift 2;;
    --drift-ahead)  DRIFT_KIND="ahead";  DRIFT_VAL="${2:-}"; shift 2;;
    --drift-behind) DRIFT_KIND="behind"; DRIFT_VAL="${2:-}"; shift 2;;
    --copy-matched) COPY_MATCHED=1; shift;;
    --no-overwrite) OVERWRITE=0; shift;;
    --max-ext) MAX_EXT_SECS="${2:-0}"; shift 2;;
    --verbose) VERBOSE=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --photos DIR [--pool DIR] --from-tz Z --to-tz Z [--drift-ahead V|--drift-behind V]
     [--tz-tag ±HH:MM] [--copy-matched] [--no-overwrite] [--max-ext SECS] [--verbose] [--dry-run]

Z (timezone) may be: UTC+3, +03:00, +5, -04:30, Z, UTC.
Drift V: 3m, 45s, 1:30m   (no +/-; use ahead/behind)

Example (your case): camera UTC+3, actual UTC+5, camera ahead 3m
  $0 --photos /data/2025-07-28_test --pool /data/Downloads \\
     --from-tz UTC+3 --to-tz UTC+5 --drift-ahead 3m --tz-tag +05:00 \\
     --copy-matched --verbose
EOF
      exit 0;;
    *) die "Unknown arg: $1";;
  esac
done
[[ -d "$PHOTOS_ROOT" ]] || die "--photos not found"; PHOTOS_ROOT="${PHOTOS_ROOT%/}"
if [[ -n "$GPX_POOL" ]]; then [[ -d "$GPX_POOL" ]] || die "--pool not found"; GPX_POOL="${GPX_POOL%/}"; fi
[[ -n "$FROM_TZ" && -n "$TO_TZ" ]] || die "--from-tz and --to-tz are required"

# ---------- helpers ----------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

# Return seconds for TZ like UTC+5, +05:00, +5, -04:30, Z, UTC
tz_to_secs(){
  local z; z="$(trim "$1")"
  [[ "$z" == "UTC" || "$z" == "utc" || "$z" == "Z" ]] && { echo 0; return; }
  [[ "$z" =~ ^UTC([+-].+)$ ]] && z="${BASH_REMATCH[1]}"
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(?::([0-9]{2}))?$ ]]; then
    local s="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" m="${BASH_REMATCH[3]:-00}"
    ((10#$h<=14)) || die "bad TZ hour: $z"; ((10#$m<=59)) || die "bad TZ min: $z"
    local t=$((10#$h*3600+10#$m*60)); [[ $s == "-" ]] && t=$((-t)); echo "$t"; return
  fi
  die "unsupported TZ '$1' (use numeric offset)"
}

secs_to_hms(){ local s=$1; local sign=""; [[ $s -lt 0 ]] && sign="-"; [[ $s -lt 0 ]] && s=$((-s)); printf "%s%d:%d:%d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60)); }

drift_to_secs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $((10#${BASH_REMATCH[1]}*60))   # (regex captures from previous line don't persist)
  elif [[ "$v" =~ ^([0-9]+)s$ ]]; then echo $((10#${BASH_REMATCH[1]}))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo $((10#$v))
  else die "Bad drift '$v' (use 3m, 45s, 1:30m)"; fi
}

et(){ [[ $VERBOSE -eq 1 ]] && echo "[ARGFILE]"; local t; t="$(mktemp)"; {
  echo "-P"
  [[ $OVERWRITE -eq 1 ]] && echo "-overwrite_original"
  [[ $MAX_EXT_SECS -gt 0 ]] && echo "-api GeoMaxExtSecs=$MAX_EXT_SECS"
  while [[ $# -gt 0 && "$1" != "--" ]]; do echo "$1"; shift; done
  [[ "${1:-}" == "--" ]] && shift
  while [[ $# -gt 0 ]]; do echo "$1"; shift; done
} >"$t"
[[ $VERBOSE -eq 1 ]] && sed 's/^/  /' "$t"
[[ $DRYRUN -eq 1 ]] || exiftool -@ "$t"
rm -f "$t"; }

dto_epoch(){ # file -> UTC epoch (using OffsetTimeOriginal or forced TZ)
  local f="$1" tz="$2" dto
  dto="$(exiftool -q -q -n -S -DateTimeOriginal "$f" | awk '{print $2" "$3}')" || return 1
  [[ -z "$tz" ]] && tz="$(exiftool -q -q -n -S -OffsetTimeOriginal "$f" | awk '/OffsetTimeOriginal/{print $2}')"
  [[ -z "$tz" ]] && return 1
  dto="${dto/:/-}"; dto="${dto/:/-}"
  date -ud "$dto $tz" +%s 2>/dev/null || return 1
}

gpx_span(){ # print "start end" epoch for GPX or nothing
  local g="$1" a b
  a="$(grep -o '<time>[^<]*</time>' "$g" | head -1 | sed -E 's#</?time>##g')" || return 1
  b="$(grep -o '<time>[^<]*</time>' "$g" | tail -1 | sed -E 's#</?time>##g')" || return 1
  [[ -n "$a" && -n "$b" ]] || return 1
  a="$(date -ud "$a" +%s 2>/dev/null || true)"; b="$(date -ud "$b" +%s 2>/dev/null || true)"
  [[ -n "$a" && -n "$b" ]] || return 1
  echo "$a $b"
}

# ---------- compute NET shift ----------
fromS=$(tz_to_secs "$FROM_TZ"); toS=$(tz_to_secs "$TO_TZ")
net=$(( toS - fromS ))   # pure TZ delta
if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
  d=$(drift_to_secs "$DRIFT_VAL")
  [[ "$DRIFT_KIND" == "ahead"  ]] && net=$(( net - d ))
  [[ "$DRIFT_KIND" == "behind" ]] && net=$(( net + d ))
fi
NET_STR="$(secs_to_hms "$net")"               # signed H:M:S
NET_ABS="${NET_STR#-}"; NET_ABS="${NET_ABS#+}"# H:M:S w/o sign

# format TZ string for tags and geotime
to_abs=$toS; tsgn="+"; [[ $to_abs -lt 0 ]] && tsgn="-" && to_abs=$((-to_abs))
TO_TZ_STR=$(printf "%s%02d:%02d" "$tsgn" $((to_abs/3600)) $(((to_abs%3600)/60)))
[[ -n "$TZ_TAG" ]] && TO_TZ_STR="$TZ_TAG"

# ---------- Phase 1: shift + TZ tags ----------
find "$PHOTOS_ROOT" -type d -print0 | while IFS= read -r -d '' d; do
  find "$d" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 \
  | while IFS= read -r -d '' f; do
      if [[ "$NET_STR" != "+0:0:0" && "$NET_STR" != "-0:0:0" ]]; then
        if [[ "${NET_STR:0:1}" == "-" ]]; then
          et "-DateTimeOriginal-=$NET_ABS" "-CreateDate-=$NET_ABS" "-ModifyDate-=$NET_ABS" -- "$f"
        else
          et "-DateTimeOriginal+=$NET_ABS" "-CreateDate+=$NET_ABS" "-ModifyDate+=$NET_ABS" -- "$f"
        fi
      fi
      et "-OffsetTimeOriginal=$TO_TZ_STR" "-OffsetTime=$TO_TZ_STR" "-OffsetTimeDigitized=$TO_TZ_STR" -- "$f"
    done
done

# ---------- Phase 2: geotag ----------
echo "Geotagging..."
find "$PHOTOS_ROOT" -type d -print0 | while IFS= read -r -d '' d; do
  shopt -s nullglob
  local_gpx=( "$d"/*.gpx "$d"/*.GPX )
  pool_gpx=( ); [[ -n "$GPX_POOL" ]] && pool_gpx=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX )
  shopt -u nullglob

  find "$d" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 \
  | while IFS= read -r -d '' f; do
      # ALWAYS force TZ at match time
      geotime="-geotime<\${DateTimeOriginal}${TO_TZ_STR}>"

      # Try local GPX dir first
      tagged=0
      if (( ${#local_gpx[@]} )); then
        et "$geotime" -geotag "$d" -- "$f" || true
        exiftool -q -q -n -GPSLatitude "$f" >/dev/null && tagged=1
      fi

      # Pool fallback: prefilter by time window
      if (( tagged==0 && ${#pool_gpx[@]} )); then
        pe="$(dto_epoch "$f" "$TO_TZ_STR" || true)"
        for g in "${pool_gpx[@]}"; do
          span="$(gpx_span "$g" || true)"
          if [[ -n "$pe" && -n "$span" ]]; then
            gs=$(awk '{print $1}' <<<"$span"); ge=$(awk '{print $2}' <<<"$span")
            as=$gs; ae=$ge
            (( MAX_EXT_SECS > 0 )) && { as=$((gs-MAX_EXT_SECS)); ae=$((ge+MAX_EXT_SECS)); }
            if ! (( pe>=as && pe<=ae )); then
              [[ $VERBOSE -eq 1 ]] && echo "[skip GPX] $(basename "$g") (photo outside $gs-$ge)"
              continue
            fi
          fi
          et "$geotime" -geotag "$g" -- "$f" || true
          if exiftool -q -q -n -GPSLatitude "$f" >/dev/null; then
            tagged=1
            if (( COPY_MATCHED==1 && DRYRUN==0 )); then
              dst="$d/$(basename "$g")"
              if [[ -e "$dst" ]]; then n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done; dst="${dst%.*}_$n.${dst##*.}"; fi
              cp -n "$g" "$dst" || true
            fi
            break
          fi
        done
      fi

      [[ $VERBOSE -eq 1 ]] && {
        if (( tagged==1 )); then exiftool -q -q -n -S -GPSLatitude -GPSLongitude "$f" | sed 's/^/[GPS] /'
        else echo "[NO MATCH] $(basename "$f")"; fi
      }
    done
done
echo "Done."
