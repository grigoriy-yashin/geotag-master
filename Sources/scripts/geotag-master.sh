#!/usr/bin/env bash
set -euo pipefail

# geotag-smart.sh  —  transparent TZ + drift + auto-GPX matching for iNaturalist
# Requires: exiftool (and GNU coreutils 'date' if you use IANA zones)
#
# Quick examples:
#   # Camera showed Moscow (UTC+3), actual Astana (UTC+6), camera 2 minutes fast:
#   ./geotag-smart.sh --photos /data/photos --pool /data/gpx \
#     --from-tz UTC+3 --to-tz UTC+6 --drift-ahead 2m \
#     --write-time --write-tz-tags --copy-matched
#
#   # Same using IANA zones instead of fixed offsets:
#   ./geotag-smart.sh --photos /data/photos --pool /data/gpx \
#     --from-tz Europe/Moscow --to-tz Asia/Almaty --drift-ahead 2m \
#     --write-time --write-tz-tags

# -------------------- Defaults --------------------
PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""            # e.g. UTC+3 or Europe/Moscow (camera wall clock at shooting)
TO_TZ=""              # e.g. UTC+6 or Asia/Almaty (actual local time you want in iNat)

DRIFT_KIND=""         # ahead|behind|exact
DRIFT_VAL=""          # e.g. 2m, 1:30m, 45s (no sign for ahead/behind; exact may include sign)

WRITE_TIME=0          # rewrite EXIF wall time (DateTimeOriginal/CreateDate/ModifyDate) to TO_TZ
WRITE_TZ_TAGS=0       # write EXIF OffsetTime* tags to match TO_TZ (for iNat correctness)

OVERWRITE=0           # 1 = no _original backups
COPY_MATCHED=0        # 1 = copy matched pool GPX into the folder it tags
RETAG_MODE="missing"  # missing|overwrite (default: fill only missing GPS)
DRYRUN=0              # 1 = print, don't execute

# Photo extensions to process
EXTS=(jpg jpeg orf rw2 arw cr2 dng nef heic heif tif tiff)

# -------------------- Help --------------------
die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'USAGE'
Usage:
  geotag-smart.sh --photos PATH --pool PATH --from-tz ZONE --to-tz ZONE [options]

Meaning:
  --from-tz   Time zone your CAMERA CLOCK showed at shooting time
  --to-tz     ACTUAL local time zone of your observations (what iNaturalist should show)

Time zone formats for --from-tz / --to-tz:
  • IANA zone name:  Europe/Moscow, Asia/Almaty, America/New_York
    (Uses the zone's CURRENT UTC offset at run time; DST isn't inferred per photo.)
  • Numeric offsets: UTC+6, UTC-3:30, +6, -04:00, Z, UTC
    (Exact fixed offsets; recommended for predictability.)

Optional drift (no +/- thinking):
  --drift-ahead  2m      # camera runs 2 minutes fast
  --drift-behind 30s     # camera runs 30 seconds slow
  --drift-exact  +75s    # explicit signed shift if you truly want to specify a sign

iNaturalist-friendly normalization:
  --write-time           # rewrite EXIF capture times to TO_TZ (wall clock becomes actual local time)
  --write-tz-tags        # write OffsetTimeOriginal/OffsetTime/OffsetTimeDigitized for iNat (+06:00 etc.)

Behavior:
  --copy-matched         # copy a pool GPX into the folder it successfully tags
  --retag overwrite      # allow overwriting existing GPS (default: only fill missing GPS)
  --overwrite            # do not keep _original backups
  --dry-run              # print actions only
  -h, --help             # show this help

Examples:
  # Moscow -> Astana, camera 2 min fast, iNat-ready:
  ./geotag-smart.sh --photos /data/photos --pool /data/gpx \
    --from-tz UTC+3 --to-tz UTC+6 --drift-ahead 2m \
    --write-time --write-tz-tags --copy-matched

Notes:
  • If you omit --write-time/--write-tz-tags, EXIF capture times remain as-shot (only GPS is added).
  • ExifTool does not depend on your machine timezone in this workflow.
USAGE
}

# -------------------- Parse args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --photos) PHOTOS_ROOT="${2:-}"; shift 2;;
    --pool) GPX_POOL="${2:-}"; shift 2;;
    --from-tz) FROM_TZ="${2:-}"; shift 2;;
    --to-tz) TO_TZ="${2:-}"; shift 2;;

    --drift-ahead)  DRIFT_KIND="ahead";  DRIFT_VAL="${2:-}"; shift 2;;
    --drift-behind) DRIFT_KIND="behind"; DRIFT_VAL="${2:-}"; shift 2;;
    --drift-exact)  DRIFT_KIND="exact";  DRIFT_VAL="${2:-}"; shift 2;;

    --write-time) WRITE_TIME=1; shift;;
    --write-tz-tags) WRITE_TZ_TAGS=1; shift;;

    --overwrite) OVERWRITE=1; shift;;
    --copy-matched) COPY_MATCHED=1; shift;;
    --retag)
      [[ "${2:-}" =~ ^(missing|overwrite)$ ]] || die "--retag must be 'missing' or 'overwrite'"
      RETAG_MODE="$2"; shift 2;;
    --dry-run) DRYRUN=1; shift;;

    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

[[ -d "$PHOTOS_ROOT" ]] || die "--photos '$PHOTOS_ROOT' not found"
[[ -d "$GPX_POOL"   ]] || die "--pool '$GPX_POOL' not found"
[[ -n "$FROM_TZ"    ]] || die "--from-tz is required"
[[ -n "$TO_TZ"      ]] || die "--to-tz is required"

# -------------------- Helpers --------------------
# Parse TZ as IANA or numeric offset; return seconds from UTC.
# Supported numeric: Z, UTC, UTC+5, UTC-3:30, +06, -04:00
parse_tz_to_seconds() {
  local z="$1"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then
    echo 0; return
  fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then
    z="${BASH_REMATCH[1]}"
  fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(?::?([0-9]{2}))?$ ]]; then
    local sign="${BASH_REMATCH[1]}"
    local hh="${BASH_REMATCH[2]}"
    local mm="${BASH_REMATCH[3]:-00}"
    (( 10#$hh <= 14 )) || die "Hour out of range in TZ offset: $z"
    (( 10#$mm <= 59 )) || die "Minute out of range in TZ offset: $z"
    local secs=$((10#$hh*3600 + 10#$mm*60))
    [[ "$sign" == "-" ]] && secs=$((-secs))
    echo "$secs"; return
  fi
  # IANA zone; take current offset (deterministic at run time)
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown time zone: $z"
  local s; s="$(TZ="$z" date +%z)"  # e.g. +0600
  local sign="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60))
  [[ "$sign" == "-" ]] && secs=$((-secs))
  echo "$secs"
}

secs_to_hms(){
  local s=$1 sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$(( -s ))
  local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sc=$(( s%60 ))
  printf "%s%d:%d:%d" "$sign" "$h" "$m" "$sc"
}

# Parse drift strings like 2m, 1:30m, 45s, +75s; return absolute seconds (positive)
parse_drift_value_abs() {
  local v="$1"
  if [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then
    echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} )); return
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo $(( ${BASH_REMATCH[1]}*60 )); return
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then
    echo $(( ${BASH_REMATCH[2]} )); return
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then
    echo "$v"; return
  fi
  die "Unsupported drift format '$v' (use 2m, 1:30m, 45s, +75s)"
}

# For --drift-exact, allow an optional sign; return signed seconds
parse_drift_exact_signed() {
  local v="$1" sign="+" num=""
  if [[ "$v" =~ ^([+-])(.*)$ ]]; then sign="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi
  local abs; abs="$(parse_drift_value_abs "$v")"
  [[ "$sign" == "-" ]] && echo $((-abs)) || echo "$abs"
}

run(){
  if [[ $DRYRUN -eq 1 ]]; then
    printf "[DRY] exiftool"
    for a in "${common[@]}"; do printf " %q" "$a"; done
    while [[ $# -gt 0 ]]; do printf " %q" "$1"; shift; done
    printf "\n"
  else
    exiftool "${common[@]}" "$@"
  fi
}

# -------------------- Build parameters --------------------
FROM_OFFS=$(parse_tz_to_seconds "$FROM_TZ")
TO_OFFS=$(parse_tz_to_seconds "$TO_TZ")

# Drift in seconds (signed according to ahead/behind/exact policy)
DRIFT_SECS=0
if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
  case "$DRIFT_KIND" in
    ahead)   DRIFT_SECS=$(( - $(parse_drift_value_abs "$DRIFT_VAL") )) ;;  # camera ahead -> subtract from track
    behind)  DRIFT_SECS=$((   $(parse_drift_value_abs "$DRIFT_VAL") )) ;;  # camera behind -> add to track
    exact)   DRIFT_SECS=$(parse_drift_exact_signed "$DRIFT_VAL") ;;
    *) die "Invalid DRIFT_KIND '$DRIFT_KIND'";;
  esac
fi

# Geotagging sync: shift GPX (UTC) into camera wall-clock (FROM_TZ), then apply drift
GEO_SYNC_LIST=()
GEO_SYNC_LIST+=("0:0:0 $(secs_to_hms $FROM_OFFS)")
[[ $DRIFT_SECS -ne 0 ]] && GEO_SYNC_LIST+=("0:0:0 $(secs_to_hms $DRIFT_SECS)")

# If rewriting EXIF times: move camera wall time to actual local time (TO_TZ), plus drift correction
NET_DELTA=$(( TO_OFFS - FROM_OFFS + DRIFT_SECS ))

# ExifTool common args
common=(-P) # preserve file modtimes
[[ $OVERWRITE -eq 1 ]] && common+=(-overwrite_original)

# -ext args
ext_args=(); for e in "${EXTS[@]}"; do ext_args+=(-ext "$e"); done

# -------------------- Summary --------------------
echo "Photos root   : $PHOTOS_ROOT"
echo "GPX pool      : $GPX_POOL"
echo "Camera TZ     : $FROM_TZ (offset $(secs_to_hms $FROM_OFFS))"
echo "Actual TZ     : $TO_TZ   (offset $(secs_to_hms $TO_OFFS))"
if [[ -n "$DRIFT_KIND" ]]; then
  echo "Camera drift  : $DRIFT_KIND $DRIFT_VAL  => $(secs_to_hms $DRIFT_SECS)"
else
  echo "Camera drift  : none"
fi
echo "Geotag syncs  : ${GEO_SYNC_LIST[*]}"
echo "Rewrite times : $([[ $WRITE_TIME -eq 1 ]] && echo YES || echo NO)   (net $(secs_to_hms $NET_DELTA))"
echo "Write TZ tags : $([[ $WRITE_TZ_TAGS -eq 1 ]] && echo YES || echo NO)"
echo "Retag mode    : $RETAG_MODE"
echo "Copy matched  : $([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
echo "Overwrite     : $([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
echo "Dry run       : $([[ $DRYRUN -eq 1 ]] && echo YES || echo NO)"
echo

# -------------------- Optionally rewrite EXIF times --------------------
if [[ $WRITE_TIME -eq 1 ]]; then
  if [[ $NET_DELTA -ne 0 ]]; then
    shift_hms=$(secs_to_hms $NET_DELTA)
    # Shift typical capture fields; include ModifyDate to keep tools in sync
    run "-DateTimeOriginal+=${shift_hms#}" "-CreateDate+=${shift_hms#}" "-ModifyDate+=${shift_hms#}" \
        -r "${ext_args[@]}" "$PHOTOS_ROOT" >/dev/null
  fi

  if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
    # Write EXIF offset tags to match TO_TZ
    to_abs=$TO_OFFS; to_sign="+"; [[ $to_abs -lt 0 ]] && to_sign="-" && to_abs=$(( -to_abs ))
    to_h=$(printf "%02d" $(( to_abs/3600 ))); to_m=$(printf "%02d" $(( (to_abs%3600)/60 )))
    tzstr="${to_sign}${to_h}:${to_m}"
    run "-OffsetTimeOriginal=$tzstr" "-OffsetTime=$tzstr" "-OffsetTimeDigitized=$tzstr" \
        -r "${ext_args[@]}" "$PHOTOS_ROOT" >/dev/null
  fi
fi

# -------------------- Geotagging --------------------
# Build geotag args
geo_args=()
for s in "${GEO_SYNC_LIST[@]}"; do geo_args+=(-geosync="$s"); done

echo "Pass 1: apply folder-local GPX (non-recursive)…"
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  gpx_here=("$dir"/*.gpx "$dir"/*.GPX)
  shopt -u nullglob
  [[ ${#gpx_here[@]} -eq 0 ]] && continue

  if [[ "$RETAG_MODE" == "missing" ]]; then
    run "${geo_args[@]}" -geotag "$dir" "${ext_args[@]}" -if "not \$gpslatitude" -r:="-" "$dir" >/dev/null
  else
    run "${geo_args[@]}" -geotag "$dir" "${ext_args[@]}" -r:="-" "$dir" >/dev/null
  fi
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Pass 2: auto-match pool GPX to folders still missing GPS…"
shopt -s nullglob
pool_gpx=("$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX)
shopt -u nullglob

if [[ ${#pool_gpx[@]} -gt 0 ]]; then
  while IFS= read -r -d '' dir; do
    # skip if folder already has its own GPX
    shopt -s nullglob; has_local=( "$dir"/*.gpx "$dir"/*.GPX ); shopt -u nullglob
    [[ ${#has_local[@]} -gt 0 ]] && continue

    # count missing
    missing_count=$(exiftool -q -q -r:="-" -if "not \$gpslatitude" "${ext_args[@]}" -T -filename "$dir" | wc -l | tr -d ' ')
    [[ "$missing_count" -eq 0 ]] && continue

    for gpx in "${pool_gpx[@]}"; do
      out=$(run "${geo_args[@]}" -geotag "$gpx" "${ext_args[@]}" -if "not \$gpslatitude" -r:="-" "$dir" 2>&1 || true)
      # sum "... image files updated/created"
      updated=$(grep -Eo '[0-9]+ image files (updated|created)' <<<"$out" | awk '{s+=$1} END{print s+0}')
      [[ $DRYRUN -eq 1 ]] && updated=1

      if [[ ${updated:-0} -gt 0 ]]; then
        if [[ $COPY_MATCHED -eq 1 && $DRYRUN -eq 0 ]]; then
          cp -n "$gpx" "$dir/" || true
        fi
        # check if any still missing; if none, move to next folder
        missing_count=$(exiftool -q -q -r:="-" -if "not \$gpslatitude" "${ext_args[@]}" -T -filename "$dir" | wc -l | tr -d ' ')
        [[ "$missing_count" -eq 0 ]] && break
      fi
    done
  done < <(find "$PHOTOS_ROOT" -type d -print0)
else
  echo "  (No GPX in pool)"
fi

echo "Done."
echo "Verify sample:"
echo "  exiftool -GPSLatitude -GPSLongitude -DateTimeOriginal -OffsetTimeOriginal -n -r \"$PHOTOS_ROOT\" | head -80"
