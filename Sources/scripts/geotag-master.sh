#!/usr/bin/env bash
set -euo pipefail

# geotag-master.sh — minimal + robust
# All exiftool writes go via -@ argfile to avoid quoting issues.

PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""
TO_TZ=""
SHIFT_EXPLICIT=""      # ±H:M:S  (overrides FROM/TO/DRIFT math)
TZ_TAG=""              # ±HH:MM  (writes OffsetTime tags)

DRIFT_KIND=""          # ahead|behind|exact
DRIFT_VAL=""

COPY_MATCHED=0
OVERWRITE=1
VERBOSE=0
DRYRUN=0
MAX_EXT_SECS=0

die(){ echo "Error: $*" >&2; exit 1; }
say(){ echo "$*"; }
cmd(){ [[ $VERBOSE -eq 1 ]] && say "$*"; }

usage(){
  say "Usage:"
  say "  $0 --photos DIR [--pool DIR]"
  say "     [--from-tz Z --to-tz Z | --shift ±H:M:S] [--drift-ahead V|--drift-behind V|--drift-exact ±S]"
  say "     [--tz-tag ±HH:MM] [--copy-matched] [--no-overwrite] [--max-ext SECS] [--verbose] [--dry-run]"
  say
  say "Meaning:"
  say "  Phase 1: shift AllDates by NET = (to − from) − ahead + behind  (or use --shift), then write OffsetTime* if asked."
  say "  Phase 2: geotag with '-geotime<\${DateTimeOriginal}+TZ>'. If Phase 1 ran, no drift again; else drift via -geosync only."
  exit 1
}

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --photos) PHOTOS_ROOT="${2:-}"; shift 2;;
    --pool) GPX_POOL="${2:-}"; shift 2;;
    --from-tz) FROM_TZ="${2:-}"; shift 2;;
    --to-tz) TO_TZ="${2:-}"; shift 2;;
    --shift) SHIFT_EXPLICIT="${2:-}"; shift 2;;
    --tz-tag|--set-offset) TZ_TAG="${2:-}"; shift 2;;
    --drift-ahead)  DRIFT_KIND="ahead";  DRIFT_VAL="${2:-}"; shift 2;;
    --drift-behind) DRIFT_KIND="behind"; DRIFT_VAL="${2:-}"; shift 2;;
    --drift-exact)  DRIFT_KIND="exact";  DRIFT_VAL="${2:-}"; shift 2;;
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
if [[ -n "$GPX_POOL" ]]; then [[ -d "$GPX_POOL" ]] || die "--pool not found"; fi
PHOTOS_ROOT="${PHOTOS_ROOT%/}"; [[ -n "$GPX_POOL" ]] && GPX_POOL="${GPX_POOL%/}"

# ---------- helpers ----------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

parse_tz_to_seconds(){
  local z; z="$(trim "$1")"
  [[ -z "$z" ]] && die "empty TZ"
  if [[ "$z" == "UTC" || "$z" == "utc" || "$z" == "Z" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(?::([0-9]{2}))?$ ]]; then
    local s="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" m="${BASH_REMATCH[3]:-00}"
    ((10#$h<=14)) || die "TZ hour out of range: $z"; ((10#$m<=59)) || die "TZ minute out of range: $z"
    local t=$((10#$h*3600+10#$m*60)); [[ $s == "-" ]] && t=$((-t)); echo "$t"; return
  fi
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown TZ: $z"
  local off; off="$(TZ="$z" date +%z)"; local s="${off:0:1}" h="${off:1:2}" m="${off:3:2}"
  local t=$((10#$h*3600+10#$m*60)); [[ $s == "-" ]] && t=$((-t)); echo "$t"
}

abs_hms(){ local s=$1; [[ $s -lt 0 ]] && s=$((-s)); printf "%d:%d:%d" $((s/3600)) $(((s%3600)/60)) $((s%60)); }
drift_to_seconds(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Bad drift '$v' (use 3m, 45s, 1:30m, +75s)"; fi
}
drift_exact_seconds(){
  local v="$1" sgn="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sgn="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi
  local a; a="$(drift_to_seconds "$v")"; [[ $sgn == "-" ]] && echo $((-a)) || echo "$a"
}

xt_argfile(){ # -@ runner
  local tmp; tmp="$(mktemp)"
  echo "-P" >>"$tmp"
  [[ $OVERWRITE -eq 1 ]] && echo "-overwrite_original" >>"$tmp"
  [[ $MAX_EXT_SECS -gt 0 ]] && echo "-api GeoMaxExtSecs=$MAX_EXT_SECS" >>"$tmp"
  # options (until --)
  while [[ $# -gt 0 && "$1" != "--" ]]; do printf '%s\n' "$1" >>"$tmp"; shift; done
  [[ "${1:-}" == "--" ]] && shift
  # files
  while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >>"$tmp"; shift; done
  if [[ $VERBOSE -eq 1 ]]; then echo "[ARGFILE]"; sed 's/^/  /' "$tmp"; fi
  [[ $DRYRUN -eq 1 ]] || exiftool -@ "$tmp"
  rm -f "$tmp"
}

# ---------- compute NET shift ----------
NET_SHIFT_STR=""; APPLIED_SHIFT=0
if [[ -n "$SHIFT_EXPLICIT" ]]; then
  [[ "$SHIFT_EXPLICIT" =~ ^[+-][0-9]+:[0-9]+:[0-9]+$ ]] || die "--shift must be ±H:M:S"
  NET_SHIFT_STR="$SHIFT_EXPLICIT"; APPLIED_SHIFT=1
elif [[ -n "$FROM_TZ" && -n "$TO_TZ" ]]; then
  from_s=$(parse_tz_to_seconds "$FROM_TZ"); to_s=$(parse_tz_to_seconds "$TO_TZ")
  shift_s=$(( to_s - from_s ))   # pure TZ delta
  case "$DRIFT_KIND" in
    ahead)   [[ -n "$DRIFT_VAL" ]] && shift_s=$(( shift_s - $(drift_to_seconds "$DRIFT_VAL") ));;
    behind)  [[ -n "$DRIFT_VAL" ]] && shift_s=$(( shift_s + $(drift_to_seconds "$DRIFT_VAL") ));;
    exact)   [[ -n "$DRIFT_VAL" ]] && shift_s=$(( shift_s + $(drift_exact_seconds "$DRIFT_VAL") ));;
    "" ) :;;
    * ) die "drift kind must be ahead|behind|exact";;
  esac
  if [[ $shift_s -gt 0 ]]; then NET_SHIFT_STR="+$(abs_hms "$shift_s")"
  elif [[ $shift_s -lt 0 ]]; then NET_SHIFT_STR="-$(abs_hms "$shift_s")"
  else NET_SHIFT_STR=""; fi
  [[ -n "$NET_SHIFT_STR" ]] && APPLIED_SHIFT=1
fi

# ---------- Phase 1: time rewrite + tz tags ----------
if [[ $APPLIED_SHIFT -eq 1 || -n "$TZ_TAG" || -n "$TO_TZ" ]]; then
  find "$PHOTOS_ROOT" -type d -print0 | while IFS= read -r -d '' dir; do
    find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 \
    | while IFS= read -r -d '' f; do
        if [[ $APPLIED_SHIFT -eq 1 && -n "$NET_SHIFT_STR" ]]; then
          if [[ "${NET_SHIFT_STR:0:1}" == "+" ]]; then
            xt_argfile "-DateTimeOriginal+=${NET_SHIFT_STR:1}" "-CreateDate+=${NET_SHIFT_STR:1}" "-ModifyDate+=${NET_SHIFT_STR:1}" -- "$f"
          else
            xt_argfile "-DateTimeOriginal-=${NET_SHIFT_STR:1}" "-CreateDate-=${NET_SHIFT_STR:1}" "-ModifyDate-=${NET_SHIFT_STR:1}" -- "$f"
          fi
        fi
        # Decide TZ tag to write
        if [[ -n "$TZ_TAG" || -n "$TO_TZ" ]]; then
          tztowrite="$TZ_TAG"
          if [[ -z "$tztowrite" && -n "$TO_TZ" ]]; then
            to_s=$(parse_tz_to_seconds "$TO_TZ"); s="+"; [[ $to_s -lt 0 ]] && s="-" && to_s=$((-to_s))
            tztowrite=$(printf "%s%02d:%02d" "$s" $((to_s/3600)) $(((to_s%3600)/60)))
          fi
          [[ "$tztowrite" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "--tz-tag must be ±HH:MM"
          xt_argfile "-OffsetTimeOriginal=$tztowrite" "-OffsetTime=$tztowrite" "-OffsetTimeDigitized=$tztowrite" -- "$f"
        fi
      done
  done
fi

# If we normalized timestamps, we don’t apply drift again in geotag:
GEOSYNC=""
if [[ $APPLIED_SHIFT -eq 0 && -n "$DRIFT_KIND" ]]; then
  if [[ "$DRIFT_KIND" == "ahead" ]]; then GEOSYNC="+$(abs_hms "$(drift_to_seconds "$DRIFT_VAL")")"
  elif [[ "$DRIFT_KIND" == "behind" ]]; then GEOSYNC="-$(abs_hms "$(drift_to_seconds "$DRIFT_VAL")")"
  elif [[ "$DRIFT_KIND" == "exact" ]]; then
    d=$(drift_exact_seconds "$DRIFT_VAL"); [[ $d -ge 0 ]] && GEOSYNC="+$(abs_hms "$d")" || GEOSYNC="-$(abs_hms "$d")"
  fi
fi

# Preferred TZ for geotime (from --to-tz or from --tz-tag; else fall back to per-file OffsetTimeOriginal)
GEOTZ=""
if [[ -n "$TO_TZ" ]]; then
  to_s=$(parse_tz_to_seconds "$TO_TZ"); s="+"; [[ $to_s -lt 0 ]] && s="-" && to_s=$((-to_s))
  GEOTZ=$(printf "%s%02d:%02d" "$s" $((to_s/3600)) $(((to_s%3600)/60)))
elif [[ -n "$TZ_TAG" ]]; then
  GEOTZ="$TZ_TAG"
fi

# ---------- Phase 2: geotag ----------
say "Geotagging..."
find "$PHOTOS_ROOT" -type d -print0 | while IFS= read -r -d '' dir; do
  # local & pool GPX
  shopt -s nullglob
  local_gpx=( "$dir"/*.gpx "$dir"/*.GPX )
  pool_gpx=( ); [[ -n "$GPX_POOL" ]] && pool_gpx=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX )
  shopt -u nullglob

  find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0 \
  | while IFS= read -r -d '' f; do
      # decide TZ for this file
      tz_for_file="$GEOTZ"
      if [[ -z "$tz_for_file" ]]; then
        tz_for_file="$(exiftool -q -q -n -S -OffsetTimeOriginal "$f" | awk '/OffsetTimeOriginal/ {print $2}')"
        if [[ -z "$tz_for_file" ]]; then
          say "[SKIP] $(basename "$f"): no --to-tz/--tz-tag and no OffsetTimeOriginal"
          continue
        fi
      fi
      geotime="-geotime<\${DateTimeOriginal}${tz_for_file}>"
      geosync_opt=(); [[ -n "$GEOSYNC" ]] && geosync_opt=( "-geosync=$GEOSYNC" )

      # detect whether it had GPS before
      before_has_gps=1; exiftool -q -q -n -GPSLatitude "$f" >/dev/null || before_has_gps=0

      tagged=0
      # local GPX first
      if (( ${#local_gpx[@]} )); then
        xt_argfile "$geotime" "${geosync_opt[@]}" -geotag "$dir" -- "$f" || true
        exiftool -q -q -n -GPSLatitude "$f" >/dev/null && tagged=1
      fi
      # pool fallback
      if (( tagged==0 && ${#pool_gpx[@]} )); then
        for g in "${pool_gpx[@]}"; do
          xt_argfile "$geotime" "${geosync_opt[@]}" -geotag "$g" -- "$f" || true
          if exiftool -q -q -n -GPSLatitude "$f" >/dev/null; then
            tagged=1
            if (( COPY_MATCHED==1 && DRYRUN==0 && before_has_gps==0 )); then
              dst="$dir/$(basename "$g")"
              if [[ -e "$dst" ]]; then n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done; dst="${dst%.*}_$n.${dst##*.}"; fi
              cp -n "$g" "$dst" || true
            fi
            break
          fi
        done
      fi
      if (( VERBOSE==1 )); then
        if (( tagged==1 )); then exiftool -q -q -n -S -GPSLatitude -GPSLongitude "$f" | sed 's/^/[GPS] /'
        else say "[NO MATCH] $(basename "$f")"; fi
      fi
    done
done
say "Done."
