#!/usr/bin/env bash
set -euo pipefail

# geotag-master.sh — normalize timestamps (+TZ) then geotag with GPX.
# Linux + exiftool + GNU date required.

PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""
TO_TZ=""
TZ_TAG=""          # +HH:MM to write OffsetTime* (optional)

DRIFT_KIND=""      # ahead|behind
DRIFT_VAL=""       # 3m|45s|1:30m  (no +/- signs)

GEOTAG_ONLY=0
COPY_MATCHED=0
OVERWRITE=1
VERBOSE=0
DRYRUN=0
MAX_EXT_SECS=0     # allow matching outside GPX ends by this many seconds

die(){ echo "Error: $*" >&2; exit 1; }
say(){ echo "$*"; }

usage(){
cat <<'EOF'
Usage:
  geotag-master.sh --photos DIR [--pool DIR]
                   [--from-tz Z --to-tz Z [--drift-ahead V | --drift-behind V]]
                   [--tz-tag +HH:MM]
                   [--geotag-only]
                   [--copy-matched] [--no-overwrite]
                   [--max-ext SECS] [--verbose] [--dry-run]

What it does
------------
Two modes:

1) Default (normalize + geotag)
   - Computes NET shift for your timestamps:
       NET = (to − from) − ahead + behind
     Examples:
       camera UTC+3, actual UTC+5, camera ahead 3m → NET = +01:57:00
   - Shifts: DateTimeOriginal, CreateDate, ModifyDate by NET.
   - Writes TZ tags: OffsetTimeOriginal/OffsetTime/OffsetTimeDigitized (to +HH:MM).
   - Geotags using:
       -geotime<${DateTimeOriginal}+TZ>
     (No -geosync; drift already baked into time.)

2) --geotag-only
   - Skips all timestamp shifts and drift.
   - Does NOT touch OffsetTime* unless you also pass --tz-tag.
   - Still geotags with:
       -geotime<${DateTimeOriginal}+TZ>
     TZ is taken from: --tz-tag, else --to-tz, else file's OffsetTimeOriginal.
     If none are available, file is skipped.

GPX selection
-------------
- Tries GPX files in the photo folder first (all of them).
- Falls back to GPX files from --pool.
- For pool GPX, only tries files whose time window overlaps the photo time
  (UTC), allowing --max-ext seconds extension at both ends.
- If a pool GPX newly tags a file (which previously had no GPS), it is
  copied into that photo folder when --copy-matched is set.

Inputs
------
Z timezones: UTC+3, +03:00, +3, -04:30, UTC, Z
Drift V:     3m, 45s, 1:30m  (choose ahead/behind; no +/- signs)

Examples
--------
# Full workflow in one command:
geotag-master.sh \
  --photos /data/2025-07-28 \
  --pool /data/Downloads \
  --from-tz UTC+3 --to-tz UTC+5 --drift-ahead 3m \
  --tz-tag +05:00 --copy-matched --verbose

# Geotag-only when camera/phone time is already correct:
geotag-master.sh \
  --photos /data/2025-07-28 \
  --pool /data/GPX \
  --geotag-only --copy-matched --verbose
EOF
exit 0
}

# ---------------- args ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --photos) PHOTOS_ROOT="${2:-}"; shift 2;;
    --pool)   GPX_POOL="${2:-}"; shift 2;;

    --from-tz) FROM_TZ="${2:-}"; shift 2;;
    --to-tz)   TO_TZ="${2:-}"; shift 2;;
    --tz-tag|--set-offset) TZ_TAG="${2:-}"; shift 2;;

    --drift-ahead)  DRIFT_KIND="ahead";  DRIFT_VAL="${2:-}"; shift 2;;
    --drift-behind) DRIFT_KIND="behind"; DRIFT_VAL="${2:-}"; shift 2;;

    --geotag-only) GEOTAG_ONLY=1; shift;;
    --copy-matched) COPY_MATCHED=1; shift;;
    --no-overwrite) OVERWRITE=0; shift;;
    --max-ext) MAX_EXT_SECS="${2:-0}"; shift 2;;

    --verbose) VERBOSE=1; shift;;
    --dry-run) DRYRUN=1; shift;;

    -h|--help) usage;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -d "$PHOTOS_ROOT" ]] || die "--photos not found"
PHOTOS_ROOT="${PHOTOS_ROOT%/}"
if [[ -n "$GPX_POOL" ]]; then
  [[ -d "$GPX_POOL" ]] || die "--pool not found"
  GPX_POOL="${GPX_POOL%/}"
fi

# ---------------- helpers ----------------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

# Numeric TZ → seconds. Accepts: UTC+3, +03:00, +3, -04:30, UTC, Z
tz_to_secs(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "UTC" || "$z" == "utc" || "$z" == "Z" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(:([0-9]{1,2}))?$ ]]; then
    local s="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" m="${BASH_REMATCH[4]:-0}"
    ((10#$h<=14)) || die "TZ hour out of range: $z"
    ((10#$m<=59)) || die "TZ minute out of range: $z"
    local t=$((10#$h*3600 + 10#$m*60)); [[ $s == "-" ]] && t=$((-t))
    echo "$t"; return
  fi
  die "unsupported TZ '$1' (use numeric offset: UTC+5, +05:00, +5, -04:30, UTC, Z)"
}

secs_to_hms_signed(){ local s="$1" sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$((-s)); printf "%s%d:%d:%d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60)); }
secs_to_hms_abs(){ local s="$1"; [[ $s -lt 0 ]] && s=$((-s)); printf "%d:%d:%d" $((s/3600)) $(((s%3600)/60)) $((s%60)); }

# Drift strings → seconds (3m, 45s, 1:30m)
drift_to_secs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( 10#${BASH_REMATCH[1]}*60 + 10#${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then         echo $(( 10#${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([0-9]+)s$ ]]; then         echo $(( 10#${BASH_REMATCH[1]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then          echo $(( 10#$v ))
  else die "Bad drift '$v' (use 3m, 45s, 1:30m)"; fi
}

# exiftool via argfile (-@) for safe quoting
et(){
  local tmp; tmp="$(mktemp)"
  {
    echo "-P"
    [[ $OVERWRITE -eq 1 ]] && echo "-overwrite_original"
    [[ $MAX_EXT_SECS -gt 0 ]] && echo "-api GeoMaxExtSecs=$MAX_EXT_SECS"
    while [[ $# -gt 0 && "$1" != "--" ]]; do echo "$1"; shift; done
    [[ "${1:-}" == "--" ]] && shift
    while [[ $# -gt 0 ]]; do echo "$1"; shift; done
  } > "$tmp"
  [[ $VERBOSE -eq 1 ]] && { echo "[ARGFILE]"; sed 's/^/  /' "$tmp"; }
  [[ $DRYRUN -eq 1 ]] || exiftool -@ "$tmp"
  rm -f "$tmp"
}

# Get DTO plain value
get_dto(){ exiftool -q -q -n -s -s -s -DateTimeOriginal "$1" 2>/dev/null || true; }

# DTO (+ tz) → epoch UTC
dto_epoch(){
  local f="$1" tz="$2" dto
  dto="$(get_dto "$f")"; [[ -z "$dto" ]] && return 1
  [[ -z "$tz" ]] && tz="$(exiftool -q -q -n -s -s -s -OffsetTimeOriginal "$f" 2>/dev/null || true)"
  [[ -z "$tz" ]] && return 1
  local iso="${dto/:/-}"; iso="${iso/:/-}"   # YYYY-MM-DD HH:MM:SS
  date -ud "$iso $tz" +%s 2>/dev/null || return 1
}

# GPX first/last <time> → (start end) epoch UTC
gpx_span_epoch(){
  local g="$1" a b
  a="$(grep -o '<time>[^<]*</time>' "$g" | head -1 | sed -E 's#</?time>##g')" || return 1
  b="$(grep -o '<time>[^<]*</time>' "$g" | tail -1 | sed -E 's#</?time>##g')" || return 1
  [[ -n "$a" && -n "$b" ]] || return 1
  local s e
  s="$(date -ud "$a" +%s 2>/dev/null || true)"
  e="$(date -ud "$b" +%s 2>/dev/null || true)"
  [[ -n "$s" && -n "$e" ]] || return 1
  echo "$s $e"
}

# “has GPS now?”
has_gps_now(){
  local f="$1" v
  v="$(exiftool -q -q -n -S -GPSLatitude "$f" 2>/dev/null | awk -F': ' '/GPSLatitude/ {print $2}')"
  [[ -n "$v" ]]
}

# ---------------- compute NET & TZ strings ----------------
MATCH_TZ_STR=""  # +HH:MM used in -geotime<${DateTimeOriginal}+TZ>
if [[ $GEOTAG_ONLY -eq 1 ]]; then
  # In geotag-only we don't compute net shift. Decide the tz for matching:
  if [[ -n "$TZ_TAG" ]]; then
    MATCH_TZ_STR="$TZ_TAG"
  elif [[ -n "$TO_TZ" ]]; then
    toS=$(tz_to_secs "$TO_TZ"); s="+"; [[ $toS -lt 0 ]] && s="-" && toS=$((-toS))
    MATCH_TZ_STR=$(printf "%s%02d:%02d" "$s" $((toS/3600)) $(((toS%3600)/60)))
  else
    MATCH_TZ_STR=""  # will fallback to file's OffsetTimeOriginal per-file
  fi
else
  # Default: compute NET and also decide TZ tag / match tz
  [[ -n "$FROM_TZ" && -n "$TO_TZ" ]] || die "--from-tz and --to-tz are required (omit both only with --geotag-only)"
  fromS=$(tz_to_secs "$FROM_TZ")
  toS=$(tz_to_secs "$TO_TZ")
  net=$(( toS - fromS ))
  if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
    d=$(drift_to_secs "$DRIFT_VAL")
    [[ "$DRIFT_KIND" == "ahead"  ]] && net=$(( net - d ))
    [[ "$DRIFT_KIND" == "behind" ]] && net=$(( net + d ))
  fi
  NET_SIGNED="$(secs_to_hms_signed "$net")"   # e.g. +1:57:0
  NET_ABS="$(secs_to_hms_abs "$net")"         # e.g. 1:57:0

  # Build +HH:MM for tags & matching
  toAbs=$toS; tsgn="+"; [[ $toAbs -lt 0 ]] && tsgn="-" && toAbs=$((-toAbs))
  MATCH_TZ_STR=$(printf "%s%02d:%02d" "$tsgn" $((toAbs/3600)) $(((toAbs%3600)/60)))
  [[ -n "$TZ_TAG" ]] && MATCH_TZ_STR="$TZ_TAG"
  [[ "$MATCH_TZ_STR" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "bad --tz-tag/--to-tz offset (need +HH:MM)"
fi

# ---------------- Phase 1: normalize times (+TZ tags) ----------------
if [[ $GEOTAG_ONLY -eq 0 ]]; then
  find "$PHOTOS_ROOT" -type d -print0 | while IFS= read -r -d '' d; do
    find "$d" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 \
    | while IFS= read -r -d '' f; do
        # Shift AllDates if NET != 0
        if [[ "$NET_SIGNED" != "+0:0:0" && "$NET_SIGNED" != "-0:0:0" ]]; then
          if [[ "${NET_SIGNED:0:1}" == "-" ]]; then
            et "-DateTimeOriginal-=${NET_ABS}" "-CreateDate-=${NET_ABS}" "-ModifyDate-=${NET_ABS}" -- "$f"
          else
            et "-DateTimeOriginal+=${NET_ABS}" "-CreateDate+=${NET_ABS}" "-ModifyDate+=${NET_ABS}" -- "$f"
          fi
        fi
        # Always write TZ tags in default mode (use TZ_TAG if given, otherwise TO_TZ)
        et "-OffsetTimeOriginal=${MATCH_TZ_STR}" "-OffsetTime=${MATCH_TZ_STR}" "-OffsetTimeDigitized=${MATCH_TZ_STR}" -- "$f"
      done
  done
fi

# ---------------- Phase 2: geotag ----------------
say "Geotagging..."
find "$PHOTOS_ROOT" -type d -print0 | while IFS= read -r -d '' d; do
  shopt -s nullglob
  local_gpx=( "$d"/*.gpx "$d"/*.GPX )
  pool_gpx=( ); [[ -n "$GPX_POOL" ]] && pool_gpx=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX )
  shopt -u nullglob

  find "$d" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 \
  | while IFS= read -r -d '' f; do
      # Choose TZ for matching this file:
      tz_for_file="$MATCH_TZ_STR"
      if [[ -z "$tz_for_file" ]]; then
        tz_for_file="$(exiftool -q -q -n -s -s -s -OffsetTimeOriginal "$f" 2>/dev/null || true)"
        if [[ -z "$tz_for_file" ]]; then
          [[ $VERBOSE -eq 1 ]] && echo "[SKIP] $(basename "$f"): no tz available (pass --tz-tag or set OffsetTimeOriginal)"
          continue
        fi
      fi

      geotime="-geotime<\${DateTimeOriginal}${tz_for_file}>"

      # Try local GPX first (all of them)
      tagged=0
      if (( ${#local_gpx[@]} )); then
        et "$geotime" -geotag "$d" -- "$f" || true
        has_gps_now "$f" && tagged=1
      fi

      # Pool fallback: prefilter by time span per GPX, allow --max-ext seconds at both ends
      if (( tagged==0 && ${#pool_gpx[@]} )); then
        pe="$(dto_epoch "$f" "$tz_for_file" || true)"
        for g in "${pool_gpx[@]}"; do
          span="$(gpx_span_epoch "$g" || true)"
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
          if has_gps_now "$f"; then
            tagged=1
            if (( COPY_MATCHED==1 && DRYRUN==0 )); then
              dst="$d/$(basename "$g")"
              if [[ -e "$dst" ]]; then n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done; dst="${dst%.*}_$n.${dst##*.}"; fi
              cp "$g" "$dst" || true
            fi
            # do NOT break; other GPX may also match this album's other files
            break
          fi
        done
      fi

      if (( VERBOSE==1 )); then
        if (( tagged==1 )); then exiftool -q -q -n -S -GPSLatitude -GPSLongitude "$f" | sed 's/^/[GPS] /'
        else echo "[NO MATCH] $(basename "$f")"; fi
      fi
    done
done
say "Done."
