#!/usr/bin/env bash
set -euo pipefail

# geotag-master.sh — bulk geotag with GPX, timezone & drift correction; iNat-friendly
# Requires: exiftool (and GNU coreutils 'date' if you use IANA zones)

# -------------------- Defaults --------------------
PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""            # camera wall-clock at shooting, e.g. UTC+3 or Europe/Moscow
TO_TZ=""              # actual local time you want in EXIF/iNat, e.g. UTC+6 or Asia/Almaty

DRIFT_KIND=""         # ahead|behind|exact
DRIFT_VAL=""          # e.g. 2m, 1:30m, 45s (no sign for ahead/behind; exact may include sign)

WRITE_TIME=0          # rewrite EXIF times (DateTimeOriginal/CreateDate/ModifyDate) to TO_TZ
WRITE_TZ_TAGS=0       # write OffsetTime* tags to match TO_TZ (e.g. +06:00)

OVERWRITE=0           # 1 = no _original backups
COPY_MATCHED=0        # 1 = copy matched pool GPX into each folder it tags
RETAG_MODE="missing"  # missing|overwrite (default: only fill missing GPS)
DRYRUN=0              # 1 = print, don't execute

# Tuning
EXTS=(jpg jpeg orf rw2 arw cr2 dng nef heic heif tif tiff)
GEOMAX_INT_SECS=900   # interpolation window (seconds) for GPX matching; increase if needed

# -------------------- Help --------------------
die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'USAGE'
Usage:
  geotag-master.sh --photos PATH --pool PATH --from-tz ZONE --to-tz ZONE [options]

Meaning:
  --from-tz   Time zone your CAMERA CLOCK showed at shooting time
  --to-tz     ACTUAL local time zone you want in EXIF (what iNaturalist should show)

Time zone formats for --from-tz / --to-tz:
  • IANA zone:  Europe/Moscow, Asia/Almaty, America/New_York
    (Uses that zone's CURRENT offset at run time; DST isn't inferred per photo.)
  • Numeric:    UTC+6, UTC-3:30, +6, -04:00, Z, UTC
    (Fixed offsets; recommended for predictability.)

Optional drift (no +/- thinking):
  --drift-ahead  2m      # camera runs 2 minutes fast
  --drift-behind 30s     # camera runs 30 seconds slow
  --drift-exact  +75s    # explicit signed shift if you truly want to specify a sign

iNaturalist-friendly normalization:
  --write-time           # rewrite EXIF capture times to TO_TZ
  --write-tz-tags        # write OffsetTimeOriginal/OffsetTime/OffsetTimeDigitized (+06:00 etc.)

Behavior:
  --copy-matched         # copy a pool GPX into each folder it successfully tags
  --retag overwrite      # allow overwriting existing GPS (default: only fill missing GPS)
  --overwrite            # do not keep _original backups
  --dry-run              # print actions only (no changes)
  -h, --help             # show this help

Example (camera showed Moscow, actual Astana, camera +2 min fast):
  ./geotag-master.sh --photos /data/photos --pool /data/gpx \
    --from-tz UTC+3 --to-tz UTC+6 --drift-ahead 2m \
    --write-time --write-tz-tags --copy-matched
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
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

# Parse TZ as IANA or numeric offset; return seconds from UTC.
# Supported numeric: Z, UTC, UTC+5, UTC-3:30, +06, -04:00
parse_tz_to_seconds() {
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(?::?([0-9]{2}))?$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]:-00}"
    (( 10#$hh <= 14 )) || die "Hour out of range in TZ offset: $z"
    (( 10#$mm <= 59 )) || die "Minute out of range in TZ offset: $z"
    local secs=$((10#$hh*3600 + 10#$mm*60)); [[ "$sign" == "-" ]] && secs=$((-secs))
    echo "$secs"; return
  fi
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown time zone: $z"
  local s; s="$(TZ="$z" date +%z)"; local sign="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60)); [[ "$sign" == "-" ]] && secs=$((-secs))
  echo "$secs"
}

secs_to_hms(){
  local s=$1 sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$(( -s ))
  local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sc=$(( s%60 ))
  printf "%s%d:%d:%d" "$sign" "$h" "$m" "$sc"
}

# Parse drift like 2m, 1:30m, 45s, +75s
parse_drift_value_abs() {
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Unsupported drift format '$v' (use 2m, 1:30m, 45s, +75s)"; fi
}
parse_drift_exact_signed() {
  local v="$1" sign="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sign="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi
  local abs; abs="$(parse_drift_value_abs "$v")"; [[ "$sign" == "-" ]] && echo $((-abs)) || echo "$abs"
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

# Drift sign: camera AHEAD => add to GPX (positive); BEHIND => subtract (negative)
DRIFT_SECS=0
if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
  case "$DRIFT_KIND" in
    ahead)   DRIFT_SECS=$(parse_drift_value_abs "$DRIFT_VAL") ;;   # +seconds
    behind)  DRIFT_SECS=$(( - $(parse_drift_value_abs "$DRIFT_VAL") )) ;; # -seconds
    exact)   DRIFT_SECS=$(parse_drift_exact_signed "$DRIFT_VAL") ;;
    *) die "Invalid DRIFT_KIND '$DRIFT_KIND'";;
  esac
fi

# Geotag sync: shift GPX (UTC) into camera wall-clock (FROM_TZ), then add drift
GEO_SYNC_LIST=( "0:0:0 $(secs_to_hms $FROM_OFFS)" )
[[ $DRIFT_SECS -ne 0 ]] && GEO_SYNC_LIST+=( "0:0:0 $(secs_to_hms $DRIFT_SECS)" )

# If rewriting EXIF times: move camera wall-time to actual local (TO_TZ) + drift correction
NET_DELTA=$(( TO_OFFS - FROM_OFFS + DRIFT_SECS ))

# ExifTool common args
common=(-P) # preserve file modtimes
[[ $OVERWRITE -eq 1 ]] && common+=(-overwrite_original)

# -ext args (used when recursing for EXIF time rewrite)
ext_args=(); for e in "${EXTS[@]}"; do ext_args+=(-ext "$e"); done

# -------------------- Summary --------------------
fmt_offs(){ secs_to_hms "$1"; }
echo "Photos root   : $PHOTOS_ROOT"
echo "GPX pool      : $GPX_POOL"
echo "Camera TZ     : $FROM_TZ (offset $(fmt_offs $FROM_OFFS))"
echo "Actual TZ     : $TO_TZ   (offset $(fmt_offs $TO_OFFS))"
if [[ -n "$DRIFT_KIND" ]]; then
  echo "Camera drift  : $DRIFT_KIND $DRIFT_VAL  => $(fmt_offs $DRIFT_SECS)"
else
  echo "Camera drift  : none"
fi
echo "Geotag syncs  : ${GEO_SYNC_LIST[*]}"
echo "Rewrite times : $([[ $WRITE_TIME -eq 1 ]] && echo YES || echo NO)   (net $(fmt_offs $NET_DELTA))"
echo "Write TZ tags : $([[ $WRITE_TZ_TAGS -eq 1 ]] && echo YES || echo NO)"
echo "Retag mode    : $RETAG_MODE"
echo "Copy matched  : $([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
echo "Overwrite     : $([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
echo "Dry run       : $([[ $DRYRUN -eq 1 ]] && echo YES || echo NO)"
echo

# -------------------- Optionally rewrite EXIF times --------------------
if [[ $WRITE_TIME -eq 1 ]]; then
  if [[ $NET_DELTA -ne 0 ]]; then
    abs_sec=$(( NET_DELTA<0 ? -NET_DELTA : NET_DELTA ))
    abs_hms=$(secs_to_hms $abs_sec); abs_hms="${abs_hms#?}"  # strip sign
    if [[ $NET_DELTA -gt 0 ]]; then
      run "-AllDates+=${abs_hms}" -r "${ext_args[@]}" "$PHOTOS_ROOT"
    else
      run "-AllDates-=${abs_hms}" -r "${ext_args[@]}" "$PHOTOS_ROOT"
    fi
  fi
  if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
    to_abs=$TO_OFFS; to_sign="+"; [[ $to_abs -lt 0 ]] && to_sign="-" && to_abs=$(( -to_abs ))
    to_h=$(printf "%02d" $(( to_abs/3600 ))); to_m=$(printf "%02d" $(( (to_abs%3600)/60 )))
    tzstr="${to_sign}${to_h}:${to_m}"
    run "-OffsetTimeOriginal=$tzstr" "-OffsetTime=$tzstr" "-OffsetTimeDigitized=$tzstr" -r "${ext_args[@]}" "$PHOTOS_ROOT"
  fi
fi

# -------------------- Geotagging --------------------
# Build geotag args
geo_args=()
for s in "${GEO_SYNC_LIST[@]}"; do geo_args+=(-geosync="$s"); done
geo_args+=(-api GeoMaxIntSecs="$GEOMAX_INT_SECS")

echo "Pass 1: apply folder-local GPX (non-recursive)…"
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  gpx_here=("$dir"/*.gpx "$dir"/*.GPX)
  shopt -u nullglob
  [[ ${#gpx_here[@]} -eq 0 ]] && continue

  if [[ "$RETAG_MODE" == "missing" ]]; then
    run "${geo_args[@]}" -geotag "$dir" -if 'not $gpslatitude' "$dir"
  else
    run "${geo_args[@]}" -geotag "$dir" "$dir"
  fi
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Pass 2: try pool GPX for folders still missing GPS (non-recursive per folder)…"
shopt -s nullglob
pool_gpx=("$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX)
shopt -u nullglob

if [[ ${#pool_gpx[@]} -gt 0 ]]; then
  while IFS= read -r -d '' dir; do
    # skip if folder already has its own GPX
    shopt -s nullglob; has_local=( "$dir"/*.gpx "$dir"/*.GPX ); shopt -u nullglob
    [[ ${#has_local[@]} -gt 0 ]] && continue

    # count missing
    missing_count=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$dir" | wc -l | tr -d ' ')
    [[ "$missing_count" -eq 0 ]] && continue
    echo "  > $dir (missing GPS: ~$missing_count)"

    # Try ALL pool GPX until none missing
    for gpx in "${pool_gpx[@]}"; do
      out=$(run "${geo_args[@]}" -geotag "$gpx" -if 'not $gpslatitude' "$dir" 2>&1 || true)
      # Sum "... image files updated/created"
      updated=$(grep -Eo '[0-9]+ image files (updated|created)' <<<"$out" | awk '{s+=$1} END{print s+0}')
      if [[ ${updated:-0} -gt 0 ]]; then
        echo "     matched: $(basename "$gpx")  (+$updated)"
        if [[ $COPY_MATCHED -eq 1 && $DRYRUN -eq 0 ]]; then
          cp -n "$gpx" "$dir/" || true
        fi
        # re-count
        missing_count=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$dir" | wc -l | tr -d ' ')
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
