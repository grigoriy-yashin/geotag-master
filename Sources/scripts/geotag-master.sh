#!/usr/bin/env bash
set -euo pipefail

# geotag-master.sh — bulk geotag with GPX, timezone & drift correction; iNat-friendly
# Requires: exiftool (and GNU coreutils 'date' if you use IANA zones)

# -------------------- Defaults --------------------
PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""
TO_TZ=""

DRIFT_KIND=""         # ahead|behind|exact
DRIFT_VAL=""          # e.g. 2m, 1:30m, 45s

WRITE_TIME=0
WRITE_TZ_TAGS=0
ALSO_QT=0

OVERWRITE=0
COPY_MATCHED=0
RETAG_MODE="missing"  # missing|overwrite
DRYRUN=0
VERBOSE=0

VERBOSE_SAMPLE_COUNT=3
CHUNK_SIZE=200        # max files per exiftool invocation

# -------------------- Help --------------------
die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'USAGE'
Usage:
  geotag-master.sh --photos PATH --pool PATH --from-tz ZONE --to-tz ZONE [options]

Time zones:
  IANA names (Europe/Moscow, Asia/Almaty) or numeric (UTC+6, +05:00, -3:30, Z, UTC)

Drift:
  --drift-ahead  2m   # camera runs fast
  --drift-behind 30s  # camera runs slow
  --drift-exact  +75s # explicit signed

Time normalization:
  --write-time --write-tz-tags [--also-qt]

Behavior:
  --copy-matched  --retag overwrite  --overwrite  --dry-run  --verbose
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

parse_tz_to_seconds() {
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}"
    (( 10#$hh <= 14 )) || die "Hour out of range: $z"
    local secs=$((10#$hh*3600)); [[ "$sign" == "-" ]] && secs=$((-secs))
    echo "$secs"; return
  elif [[ "$z" =~ ^([+-])([0-9]{1,2}):([0-9]{2})$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
    (( 10#$hh <= 14 )) || die "Hour out of range: $z"
    (( 10#$mm <= 59 )) || die "Minute out of range: $z"
    local secs=$((10#$hh*3600 + 10#$mm*60)); [[ "$sign" == "-" ]] && secs=$((-secs))
    echo "$secs"; return
  fi
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown time zone: $z"
  local s; s="$(TZ="$z" date +%z)"
  local sign="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60)); [[ "$sign" == "-" ]] && secs=$((-secs))
  echo "$secs"
}

secs_to_hms(){
  local s=$1 sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$(( -s ))
  local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sc=$(( s%60 ))
  printf "%s%d:%d:%d" "$sign" "$h" "$m" "$sc"
}

parse_drift_value_abs() {
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Unsupported drift: '$v'"; fi
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

# List photo files in a dir (non-recursive), return array via nameref
list_photo_files() {
  local dir="$1"; local -n out="$2"
  out=()
  while IFS= read -r -d '' f; do out+=("$f"); done < <(
    find "$dir" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0
  )
}

# Run exiftool on file list in chunks
run_on_files() {
  local -n files="$1"; shift
  local n=${#files[@]}
  (( n == 0 )) && return 0
  local i=0
  while (( i < n )); do
    local end=$(( i + CHUNK_SIZE )); (( end > n )) && end=$n
    local slice=("${files[@]:i:end-i}")
    run "$@" "${slice[@]}"
    i=$end
  done
}

# -------------------- Build parameters --------------------
FROM_OFFS=$(parse_tz_to_seconds "$FROM_TZ")
TO_OFFS=$(parse_tz_to_seconds "$TO_TZ")

DRIFT_SECS=0
if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
  case "$DRIFT_KIND" in
    ahead)   DRIFT_SECS=$(parse_drift_value_abs "$DRIFT_VAL") ;;
    behind)  DRIFT_SECS=$(( - $(parse_drift_value_abs "$DRIFT_VAL") )) ;;
    exact)   DRIFT_SECS=$(parse_drift_exact_signed "$DRIFT_VAL") ;;
    *) die "Invalid DRIFT_KIND '$DRIFT_KIND'";;
  esac
fi

GEO_SYNC_LIST=( "0:0:0 $(secs_to_hms $FROM_OFFS)" )
[[ $DRIFT_SECS -ne 0 ]] && GEO_SYNC_LIST+=( "0:0:0 $(secs_to_hms $DRIFT_SECS)" )
geo_args=(); for s in "${GEO_SYNC_LIST[@]}"; do geo_args+=(-geosync "$s"); done

NET_DELTA=$(( TO_OFFS - FROM_OFFS + DRIFT_SECS ))

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
if [[ "$RETAG_MODE" == "overwrite" ]]; then echo "Retag mode    : overwrite"; else echo "Retag mode    : missing"; fi
echo "Copy matched  : $([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
echo "Overwrite     : $([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
echo "Dry run       : $([[ $DRYRUN -eq 1 ]] && echo YES || echo NO)"
echo "Verbose       : $([[ $VERBOSE -eq 1 ]] && echo YES || echo NO)"
echo

# -------------------- Verbose samples --------------------
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

# -------------------- Phase A: time normalization (per folder, file lists) --------------------
if [[ $WRITE_TIME -eq 1 ]]; then
  echo "Phase A: rewriting EXIF times (per folder)..."
  while IFS= read -r -d '' dir; do
    declare -a files=(); list_photo_files "$dir" files
    (( ${#files[@]} == 0 )) && continue

    if [[ $NET_DELTA -ne 0 ]]; then
      abs_sec=$(( NET_DELTA<0 ? -NET_DELTA : NET_DELTA ))
      abs_hms=$(secs_to_hms $abs_sec); abs_hms="${abs_hms#?}"
      [[ $VERBOSE -eq 1 ]] && echo "[INFO] $dir  shift AllDates by $([[ $NET_DELTA -gt 0 ]] && echo + || echo -)$abs_hms"
      if [[ $NET_DELTA -gt 0 ]]; then
        run_on_files files "-AllDates+=${abs_hms}"
      else
        run_on_files files "-AllDates-=${abs_hms}"
      fi
      if [[ $ALSO_QT -eq 1 ]]; then
        if [[ $NET_DELTA -gt 0 ]]; then
          run_on_files files "-QuickTime:CreateDate+=${abs_hms}" "-QuickTime:ModifyDate+=${abs_hms}" "-QuickTime:MediaCreateDate+=${abs_hms}" "-XMP:CreateDate+=${abs_hms}"
        else
          run_on_files files "-QuickTime:CreateDate-=${abs_hms}" "-QuickTime:ModifyDate-=${abs_hms}" "-QuickTime:MediaCreateDate-=${abs_hms}" "-XMP:CreateDate-=${abs_hms}"
        fi
      fi
    fi

    if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
      to_abs=$TO_OFFS; to_sign="+"; [[ $to_abs -lt 0 ]] && to_sign="-" && to_abs=$(( -to_abs ))
      to_h=$(printf "%02d" $(( to_abs/3600 ))); to_m=$(printf "%02d" $(( (to_abs%3600)/60 )))
      tzstr="${to_sign}${to_h}:${to_m}"
      [[ $VERBOSE -eq 1 ]] && echo "[INFO] $dir  write OffsetTime* = $tzstr"
      run_on_files files "-OffsetTimeOriginal=$tzstr" "-OffsetTime=$tzstr" "-OffsetTimeDigitized=$tzstr"
    fi
  done < <(find "$PHOTOS_ROOT" -type d -print0)
fi

# -------------------- Phase B: geotagging (per folder, file lists) --------------------
echo "Phase B: geotagging per folder..."
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  gpx_here=("$dir"/*.gpx "$dir"/*.GPX)
  shopt -u nullglob

  [[ $VERBOSE -eq 1 ]] && show_samples "$dir"

  declare -a files=(); list_photo_files "$dir" files
  (( ${#files[@]} == 0 )) && { [[ $VERBOSE -eq 1 ]] && echo "[INFO] $dir  (no photo files)"; continue; }

  # Pass 1: local GPX only
  if [[ ${#gpx_here[@]} -gt 0 ]]; then
    if [[ "$RETAG_MODE" == "missing" ]]; then
      run "${geo_args[@]}" -geotag "$dir" -if 'not $gpslatitude' "${files[@]}"
    else
      run "${geo_args[@]}" -geotag "$dir" "${files[@]}"
    fi
  fi

  # Pass 2: pool GPX for remaining files without GPS
  missing_before=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "${files[@]}" | wc -l | tr -d ' ')
  if [[ "$missing_before" -gt 0 ]]; then
    shopt -s nullglob
    pool_gpx=("$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX)
    shopt -u nullglob
    if [[ ${#pool_gpx[@]} -gt 0 ]]; then
      for gpx in "${pool_gpx[@]}"; do
        if [[ "$RETAG_MODE" == "missing" ]]; then
          run "${geo_args[@]}" -geotag "$gpx" -if 'not $gpslatitude' "${files[@]}"
        else
          run "${geo_args[@]}" -geotag "$gpx" "${files[@]}"
        fi
        missing_after=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "${files[@]}" | wc -l | tr -d ' ')
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
