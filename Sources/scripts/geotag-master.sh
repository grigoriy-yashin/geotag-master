#!/usr/bin/env bash
set -euo pipefail

# geotag-master.sh — do 2 things, in this order:
# 1) Normalize timestamps: compute net shift from --from-tz/--to-tz and drift (or take --shift explicitly),
#    then write OffsetTime* if asked.
# 2) Geotag: force TZ via -geotime<${DateTimeOriginal}+TZ>; apply ONLY drift in -geosync if (and only if) you DIDN'T normalize timestamps.
#
# All writes go through an argfile (-@) to avoid quoting issues.

PHOTOS_ROOT="."
GPX_POOL=""
FROM_TZ=""; TO_TZ=""
SHIFT_EXPLICIT=""          # ±H:M:S  (overrides FROM/TO/DRIFT math)
TZ_TAG=""                  # ±HH:MM  write OffsetTime*
DRIFT_KIND=""; DRIFT_VAL=""# ahead|behind|exact  +  3m|45s|1:30m|+75s
COPY_MATCHED=0
OVERWRITE=1
VERBOSE=0
DRYRUN=0
MAX_EXT_SECS=0             # allow matching beyond track ends (seconds), default 0

die(){ echo "Error: $*" >&2; exit 1; }

usage(){ cat <<'H'
Usage:
  geotag-master.sh --photos DIR [--pool DIR]
    [--from-tz Z --to-tz Z | --shift ±H:M:S] [--drift-ahead V|--drift-behind V|--drift-exact ±S]
    [--tz-tag ±HH:MM] [--copy-matched] [--no-overwrite] [--max-ext SECS] [--verbose] [--dry-run]

What it does:
  Phase 1 (time): shift DateTimeOriginal/CreateDate/ModifyDate by NET shift, then write OffsetTime* if asked.
    NET = (to − from)  − ahead  + behind  (+ exact if given)
    Example: camera UTC+3, actual UTC+5, camera ahead 3m ⇒ NET = +02:00:00 − 00:03:00 = +01:57:00.

  Phase 2 (geotag): use forced TZ at match time:
    '-geotime<${DateTimeOriginal}+TZ>'
    • If Phase 1 ran (timestamps normalized), DO NOT add drift again (no -geosync).
    • If Phase 1 did NOT run, apply ONLY drift in -geosync (never add timezone there).

Notes:
  • --tz-tag just writes OffsetTime*; it doesn't shift times.
  • GPX copy: only when a POOL GPX newly tags a file that previously had no GPS.

Examples:
  # Full workflow in one go (your case):
  geotag-master.sh --photos /data/2025-07-28_test --pool /data/Downloads \
    --from-tz UTC+3 --to-tz UTC+5 --drift-ahead 3m --tz-tag +05:00 \
    --copy-matched --verbose

  # If you want to be explicit about the net shift:
  geotag-master.sh --photos /data/2025-07-28_test --pool /data/Downloads \
    --shift +1:57:0 --tz-tag +05:00 --copy-matched --verbose
H
}

# ---------------- args ----------------
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
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

PHOTOS_ROOT="${PHOTOS_ROOT%/}"; [[ -d "$PHOTOS_ROOT" ]] || die "--photos not found"
if [[ -n "$GPX_POOL" ]]; then GPX_POOL="${GPX_POOL%/}"; [[ -d "$GPX_POOL" ]] || die "--pool not found"; fi

# --------------- helpers ---------------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }
parse_tz_to_seconds(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(?::([0-9]{2}))?$ ]]; then
    local s="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" m="${BASH_REMATCH[3]:-00}"
    ((10#$h<=14)) || die "bad TZ hour: $z"; ((10#$m<=59)) || die "bad TZ minute: $z"
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
drift_exact_seconds(){ local v="$1" sgn="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sgn="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi; local a; a="$(drift_to_seconds "$v")"; [[ $sgn == "-" ]] && echo $((-a)) || echo "$a"; }

xt_run(){ # write options and files to argfile; run exiftool -@
  local tmp; tmp="$(mktemp)"
  echo "-P" >>"$tmp"
  [[ $OVERWRITE -eq 1 ]] && echo "-overwrite_original" >>"$tmp"
  [[ $MAX_EXT_SECS -gt 0 ]] && echo "-api GeoMaxExtSecs=$MAX_EXT_SECS" >>"$tmp"
  while [[ $# -gt 0 && "$1" != "--" ]]; do printf '%s\n' "$1" >>"$tmp"; shift; done
  [[ "${1:-}" == "--" ]] && shift
  while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >>"$tmp"; shift; done
  if [[ $VERBOSE -eq 1 ]]; then echo "[ARGFILE]"; sed 's/^/  /' "$tmp"; fi
  [[ $DRYRUN -eq 1 ]] || exiftool -@ "$tmp"
  rm -f "$tmp"
}

# --------------- compute NET shift ---------------
NET_SHIFT_STR=""
APPLIED_SHIFT=0
if [[ -n "$SHIFT_EXPLICIT" ]]; then
  [[ "$SHIFT_EXPLICIT" =~ ^[+-][0-9]+:[0-9]+:[0-9]+$ ]] || die "--shift must be ±H:M:S"
  NET_SHIFT_STR="$SHIFT_EXPLICIT"
  APPLIED_SHIFT=1
elif [[ -n "$FROM_TZ" && -n "$TO_TZ" ]]; then
  from_s=$(parse_tz_to_seconds "$FROM_TZ"); to_s=$(parse_tz_to_seconds "$TO_TZ")
  shift_s=$(( to_s - from_s ))   # pure TZ difference
  case "$DRIFT_KIND" in
    ahead)   shift_s=$(( shift_s - $(drift_to_seconds "$DRIFT_VAL") ));;
    behind)  shift_s=$(( shift_s + $(drift_to_seconds "$DRIFT_VAL") ));;
    exact)   shift_s=$(( shift_s + $(drift_exact_seconds "$DRIFT_VAL") ));;
    "" ) :;;
    * ) die "drift kind must be ahead|behind|exact";;
  esac
  # make ±H:M:S string
  if [[ $shift_s -gt 0 ]]; then NET_SHIFT_STR="+$(abs_hms "$shift_s")"
  elif [[ $shift_s -lt 0 ]]; then NET_SHIFT_STR="-$(abs_hms "$shift_s")"
  else NET_SHIFT_STR=""; fi
  [[ -n "$NET_SHIFT_STR" ]] && APPLIED_SHIFT=1
fi

# --------------- Phase 1: time + tz tags ---------------
if [[ $APPLIED_SHIFT -eq 1 || -n "$TZ_TAG" || -n "$TO_TZ" ]]; then
  while IFS= read -r -d '' dir; do
    while IFS= read -r -d '' f; do
      if [[ $APPLIED_SHIFT -eq 1 && -n "$NET_SHIFT_STR" ]]; then
        if [[ "${NET_SHIFT_STR:0:1}" == "+" ]]; then
          xt_run "-DateTimeOriginal+=${NET_SHIFT_STR:1}" "-CreateDate+=${NET_SHIFT_STR:1}" "-ModifyDate+=${NET_SHIFT_STR:1}" -- "$f"
        else
          xt_run "-DateTimeOriginal-=${NET_SHIFT_STR:1}" "-CreateDate-=${NET_SHIFT_STR:1}" "-ModifyDate-=${NET_SHIFT_STR:1}" -- "$f"
        fi
      fi
      # write TZ tags if requested or if TO_TZ given (convenience)
      if [[ -n "$TZ_TAG" || -n "$TO_TZ" ]]; then
        if [[ -z "$TZ_TAG" ]]; then
          to_s=$(parse_tz_to_seconds "$TO_TZ"); s="+"; [[ $to_s -lt 0 ]] && s="-" && to_s=$((-to_s))
          TZ_TAG=$(printf "%s%02d:%02d" "$s" $((to_s/3600)) $(((to_s%3600)/60)))
        fi
        [[ "$TZ_TAG" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "--tz-tag must be ±HH:MM"
        xt_run "-OffsetTimeOriginal=$TZ_TAG" "-OffsetTime=$TZ_TAG" "-OffsetTimeDigitized=$TZ_TAG" -- "$f"
      fi
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0)
  done < <(find "$PHOTOS_ROOT" -type d -print0)
fi

# Decide if we should apply geosync drift in Phase 2:
# If we normalized timestamps (APPLIED_SHIFT=1), drift is already accounted for; don't re-apply.
GEOSYNC=""
if [[ $APPLIED_SHIFT -eq 0 && -n "$DRIFT_KIND" ]]; then
  if [[ "$DRIFT_KIND" == "ahead" ]]; then GEOSYNC="+$(abs_hms "$(drift_to_seconds "$DRIFT_VAL")")"
  elif [[ "$DRIFT_KIND" == "behind" ]]; then GEOSYNC="-$(abs_hms "$(drift_to_seconds "$DRIFT_VAL")")"
  elif [[ "$DRIFT_KIND" == "exact" ]]; then
    d=$(drift_exact_seconds "$DRIFT_VAL"); [[ $d -ge 0 ]] && GEOSYNC="+$(abs_hms "$d")" || GEOSYNC="-$(abs_hms "$d")"
  fi
fi

# preferred TZ for geotime
GEOTZ=""
if [[ -n "$TO_TZ" ]]; then
  to_s=$(parse_tz_to_seconds "$TO_TZ"); s="+"; [[ $to_s -lt 0 ]] && s="-" && to_s=$((-to_s))
  GEOTZ=$(printf "%s%02d:%02d" "$s" $((to_s/3600)) $(((to_s%3600)/60)))
elif [[ -n "$TZ_TAG" ]]; then
  GEOTZ="$TZ_TAG"
fi

# --------------- Phase 2: geotag ---------------
echo "Geotagging..."
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  local_gpx=( "$dir"/*.gpx "$dir"/*.GPX )
  pool_gpx=( ); [[ -n "$GPX_POOL" ]] && pool_gpx=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX )
  shopt -u nullglob

  while IFS= read -r -d '' f; do
    # choose TZ for this file
    tz_for_file="$GEOTZ"
    if [[ -z "$tz_for_file" ]]; then
      tz_for_file="$(exiftool -q -q -n -S -OffsetTimeOriginal "$f" | awk '/OffsetTimeOriginal/ {print $2}')"
      [[ -z "$tz_for_file" ]] && { echo "[SKIP] $(basename "$f"): no --to-tz/--tz-tag and no OffsetTimeOriginal"; continue; }
    fi

    geotime="-geotime<\${DateTimeOriginal}${tz_for_file}>"
    geosync=(); [[ -n "$GEOSYNC" ]] && geosync=( "-geosync=$GEOSYNC" )

    # keep track for copy detection (only copy if POOL GPX added GPS where it was missing)
    before_has_gps=1
    exiftool -q -q -n -GPSLatitude "$f" >/dev/null || before_has_gps=0

    tagged=0

    # local GPX first
    if (( ${#local_gpx[@]} )); then
      xt_run "$geotime" "${geosync[@]}" -geotag "$dir" -- "$f" || true
      exiftool -q -q -n -GPSLatitude "$f" >/dev/null && tagged=1
    fi

    # pool fallback
    if (( tagged==0 && ${#pool_gpx[@]} )); then
      for g in "${pool_gpx[@]}"; do
        xt_run "$geotime" "${geosync[@]}" -geotag "$g" -- "$f" || true
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
      if (( tagged==1 )); then
        exiftool -q -q -n -S -GPSLatitude -GPSLongitude "$f" | sed 's/^/[GPS] /'
      else
        echo "[NO MATCH] $(basename "$f")"
      fi
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0)
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Done."
