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

WRITE_TIME=0          # rewrite EXIF times (AllDates) to TO_TZ
WRITE_TZ_TAGS=0       # write OffsetTime* tags to match TO_TZ (e.g. +06:00)
ALSO_QT=0             # also shift QuickTime/HEIC times (CreateDate/MediaCreateDate) and XMP:CreateDate

OVERWRITE=0           # 1 = no _original backups
COPY_MATCHED=0        # 1 = copy matched pool GPX into each folder it tags
RETAG_MODE="missing"  # missing|overwrite (default: only fill missing GPS)
DRYRUN=0              # 1 = print, don't execute
VERBOSE=0             # 1 = detailed logging

# Extensions (lower + UPPER to be safe on Linux)
EXTS=(jpg JPG jpeg JPEG orf ORF rw2 RW2 arw ARW cr2 CR2 dng DNG nef NEF heic HEIC heif HEIF tif TIF tiff TIFF)

VERBOSE_SAMPLE_COUNT=3

# -------------------- Help --------------------
die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'USAGE'
Usage:
  geotag-master.sh --photos PATH --pool PATH --from-tz ZONE --to-tz ZONE [options]

--from-tz / --to-tz formats:
  • IANA zone:  Europe/Moscow, Asia/Almaty, America/New_York
  • Numeric:    UTC+6, UTC-3:30, +6, -04:00, Z, UTC

Drift (no +/- thinking):
  --drift-ahead  2m      # camera runs 2 minutes fast
  --drift-behind 30s     # camera runs 30 seconds slow
  --drift-exact  +75s    # explicit signed shift

Time normalization:
  --write-time           # shift EXIF capture times (AllDates) to TO_TZ
  --write-tz-tags        # write OffsetTimeOriginal/OffsetTime/OffsetTimeDigitized
  --also-qt              # also adjust QuickTime/HEIC/XMP time tags

Behavior:
  --copy-matched         # copy each matching pool GPX into that folder
  --retag overwrite      # replace existing GPS (default: only fill missing)
  --overwrite            # no _original backups
  --dry-run              # print commands only
  --verbose              # detailed logs + before/after samples
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
    --also-qt) ALSO_QT=1; shift;;
    --overwrite) OVERWRITE=1; shift;;
    --copy-matched) COPY_MATCHED=1; shift;;
    --retag) [[ "${2:-}" =~ ^(missing|overwrite)$ ]] || die "--retag must be missing|overwrite"
             RETAG_MODE="$2"; shift 2;;
    --dry-run) DRYRUN=1; shift;;
    --verbose) VERBOSE=1; shift;;
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

# Parse TZ to seconds from UTC.
# Supports: Z, UTC, UTC+5, UTC-3:30, +06, -04:00, and IANA names.
parse_tz_to_seconds() {
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  # numeric: +H, -HH, +HH:MM
  if [[ "$z" =~ ^([+-])([0-9]{1,2})$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="00"
    (( 10#$hh <= 14 )) || die "Hour out of range in TZ offset: $z"
    local secs=$((10#$hh*3600)); [[ "$sign" == "-" ]] && secs=$((-secs))
    echo "$secs"; return
  elif [[ "$z" =~ ^([+-])([0-9]{1,2}):([0-9]{2})$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
    (( 10#$hh <= 14 )) || die "Hour out of range in TZ offset: $z"
    (( 10#$mm <= 59 )) || die "Minute out of range in TZ offset: $z"
    local secs=$((10#$hh*3600 + 10#$mm*60)); [[ "$sign" == "-" ]] && secs=$((-secs))
    echo "$secs"; return
  fi
  # IANA fallback
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown time zone: $z"
  local s; s="$(TZ="$z" date +%z)"  # e.g. +0600
  local sign="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60)); [[ "$sign" == "-" ]] && secs=$((-secs))
  echo "$secs"
}

secs_to_hms(){
  local s=$1 sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$(( -s ))
  local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sc=$(( s%60 ))
  printf "%s%d:%d:%d" "$sign" "$h" "$m" "$sc"
}

# Drift parsing
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

log(){ [[ $VERBOSE -eq 1 ]] && echo "$@" >&2 || true; }

# exiftool runner
common=(-P); [[ $OVERWRITE -eq 1 ]] && common+=(-overwrite_original)
run(){
  if [[ $DRYRUN -eq 1 || $VERBOSE -eq 1 ]]; then
    printf "[CMD] exiftool"
    for a in "${common[@]}"; do printf " %q" "$a"; done
    while [[ $# -gt 0 ]]; do printf " %q" "$1"; shift; done
    printf "\n"
    [[ $DRYRUN -eq 1 ]] && return 0
  fi
  exiftool "${common[@]}" "$@"
}

# -------------------- Build parameters --------------------
FROM_OFFS=$(parse_tz_to_seconds "$FROM_TZ")
TO_OFFS=$(parse_tz_to_seconds "$TO_TZ")

# Drift sign: camera AHEAD => add to GPX (positive); BEHIND => subtract (negative)
DRIFT_SECS=0
if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
  case "$DRIFT_KIND" in
    ahead)   DRIFT_SECS=$(parse_drift_value_abs "$DRIFT_VAL") ;;
    behind)  DRIFT_SECS=$(( - $(parse_drift_value_abs "$DRIFT_VAL") )) ;;
    exact)   DRIFT_SECS=$(parse_drift_exact_signed "$DRIFT_VAL") ;;
    *) die "Invalid DRIFT_KIND '$DRIFT_KIND'";;
  esac
fi

# Geotag sync: shift GPX (UTC) into camera wall-clock (FROM_TZ), then add drift
GEO_SYNC_LIST=( "0:0:0 $(secs_to_hms $FROM_OFFS)" )
[[ $DRIFT_SECS -ne 0 ]] && GEO_SYNC_LIST+=( "0:0:0 $(secs_to_hms $DRIFT_SECS)" )
geo_args=(); for s in "${GEO_SYNC_LIST[@]}"; do geo_args+=(-geosync "$s"); done

# If rewriting EXIF times: move camera wall-time to actual local (TO_TZ) + drift correction
NET_DELTA=$(( TO_OFFS - FROM_OFFS + DRIFT_SECS ))

# -ext args for recursive passes
ext_args=(); for e in "${EXTS[@]}"; do ext_args+=(-ext "$e"); done

# -------------------- Summary --------------------
fmt_offs(){ secs_to_hms "$1"; }
echo "Photos root   : $PHOTOS_ROOT"
echo "GPX pool      : $GPX_POOL"
echo "Camera TZ     : $FROM_TZ (offset $(fmt_offs $FROM_OFFS))"
echo "Actual TZ     : $TO_TZ   (offset $(fmt_offs $TO_OFFS))"
[[ -n "$DRIFT_KIND" ]] && echo "Camera drift  : $DRIFT_KIND $DRIFT_VAL  => $(fmt_offs $DRIFT_SECS)" || echo "Camera drift  : none"
echo "Geotag syncs  : ${GEO_SYNC_LIST[*]}"
echo "Rewrite times : $([[ $WRITE_TIME -eq 1 ]] && echo YES || echo NO)   (net $(fmt_offs $NET_DELTA))"
echo "Write TZ tags : $([[ $WRITE_TZ_TAGS -eq 1 ]] && echo YES || echo NO)"
echo "Also QuickTime: $([[ $ALSO_QT -eq 1 ]] && echo YES || echo NO)"
echo "Retag mode    : $[[ $RETAG_MODE == overwrite ]] && echo overwrite || echo missing"
echo "Copy matched  : $([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
echo "Overwrite     : $([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
echo "Dry run       : $([[ $DRYRUN -eq 1 ]] && echo YES || echo NO)"
echo "Verbose       : $([[ $VERBOSE -eq 1 ]] && echo YES || echo NO)"
echo

# -------------------- Verbose: before/after samples --------------------
show_samples(){
  local dir="$1"
  [[ $VERBOSE -eq 1 ]] || return 0
  echo "[BEFORE] sample from: $dir"
  exiftool -q -q -n -S -G1 \
    -DateTimeOriginal -CreateDate -ModifyDate \
    -OffsetTimeOriginal -GPSLatitude -GPSLongitude \
    "$dir" | head -n $VERBOSE_SAMPLE_COUNT
}
show_after(){
  local dir="$1"
  [[ $VERBOSE -eq 1 ]] || return 0
  echo "[AFTER]  sample from: $dir"
  exiftool -q -q -n -S -G1 \
    -DateTimeOriginal -CreateDate -ModifyDate \
    -OffsetTimeOriginal -GPSLatitude -GPSLongitude \
    "$dir" | head -n $VERBOSE_SAMPLE_COUNT
}

# -------------------- Optionally rewrite EXIF times --------------------
if [[ $WRITE_TIME -eq 1 ]]; then
  echo "Phase A: rewriting EXIF times..."
  if [[ $NET_DELTA -ne 0 ]]; then
    abs_sec=$(( NET_DELTA<0 ? -NET_DELTA : NET_DELTA ))
    abs_hms=$(secs_to_hms $abs_sec); abs_hms="${abs_hms#?}"  # strip sign
    [[ $VERBOSE -eq 1 ]] && echo "[INFO] shifting AllDates by $([[ $NET_DELTA -gt 0 ]] && echo + || echo -)$abs_hms"
    if [[ $NET_DELTA -gt 0 ]]; then
      run "-AllDates+=${abs_hms}" -r "${ext_args[@]}" "$PHOTOS_ROOT"
    else
      run "-AllDates-=${abs_hms}" -r "${ext_args[@]}" "$PHOTOS_ROOT"
    fi
    if [[ $ALSO_QT -eq 1 ]]; then
      if [[ $NET_DELTA -gt 0 ]]; then
        run "-QuickTime:CreateDate+=${abs_hms}" "-QuickTime:ModifyDate+=${abs_hms}" \
            "-QuickTime:MediaCreateDate+=${abs_hms}" "-XMP:CreateDate+=${abs_hms}" \
            -r "${ext_args[@]}" "$PHOTOS_ROOT"
      else
        run "-QuickTime:CreateDate-=${abs_hms}" "-QuickTime:ModifyDate-=${abs_hms}" \
            "-QuickTime:MediaCreateDate-=${abs_hms}" "-XMP:CreateDate-=${abs_hms}" \
            -r "${ext_args[@]}" "$PHOTOS_ROOT"
      fi
    fi
  fi
  if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
    to_abs=$TO_OFFS; to_sign="+"; [[ $to_abs -lt 0 ]] && to_sign="-" && to_abs=$(( -to_abs ))
    to_h=$(printf "%02d" $(( to_abs/3600 ))); to_m=$(printf "%02d" $(( (to_abs%3600)/60 )))
    tzstr="${to_sign}${to_h}:${to_m}"
    [[ $VERBOSE -eq 1 ]] && echo "[INFO] writing OffsetTime* = $tzstr"
    run "-OffsetTimeOriginal=$tzstr" "-OffsetTime=$tzstr" "-OffsetTimeDigitized=$tzstr" -r "${ext_args[@]}" "$PHOTOS_ROOT"
  fi
fi

# -------------------- Geotagging --------------------
echo "Phase B: geotagging per folder..."
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  gpx_here=("$dir"/*.gpx "$dir"/*.GPX)
  shopt -u nullglob

  [[ $VERBOSE -eq 1 ]] && show_samples "$dir"

  if [[ ${#gpx_here[@]} -gt 0 ]]; then
    # Pass 1: local GPX only, non-recursive
    if [[ "$RETAG_MODE" == "missing" ]]; then
      run "${geo_args[@]}" -geotag "$dir" -if 'not $gpslatitude' "$dir"
    else
      run "${geo_args[@]}" -geotag "$dir" "$dir"
    fi
  fi

  # Pass 2: If still missing GPS, try all pool GPX (non-recursive per folder)
  missing_before=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$dir" | wc -l | tr -d ' ')
  if [[ "$missing_before" -gt 0 ]]; then
    shopt -s nullglob
    pool_gpx=("$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX)
    shopt -u nullglob
    if [[ ${#pool_gpx[@]} -gt 0 ]]; then
      for gpx in "${pool_gpx[@]}"; do
        run "${geo_args[@]}" -geotag "$gpx" -if 'not $gpslatitude' "$dir"
        # recompute remaining missing
        missing_after=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$dir" | wc -l | tr -d ' ')
        updated=$(( missing_before - missing_after ))
        if [[ $updated -gt 0 ]]; then
          echo "  [+] $(basename "$gpx") matched $dir  (updated $updated files)"
          if [[ $COPY_MATCHED -eq 1 && $DRYRUN -eq 0 ]]; then
            base="$(basename "$gpx")"; dst="$dir/$base"
            if [[ -e "$dst" ]]; then
              n=1; while [[ -e "$dir/${base%.*}_$n.${base##*.}" ]]; do n=$((n+1)); done
              dst="$dir/${base%.*}_$n.${base##*.}"
            fi
            cp -n "$gpx" "$dst" || true
          fi
        fi
        [[ $missing_after -le 0 ]] && break
        missing_before=$missing_after
      done
    fi
  fi

  [[ $VERBOSE -eq 1 ]] && show_after "$dir"

done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Done."
echo "Verify sample:"
echo "  exiftool -GPSLatitude -GPSLongitude -DateTimeOriginal -OffsetTimeOriginal -n -r \"$PHOTOS_ROOT\" | head -80"
