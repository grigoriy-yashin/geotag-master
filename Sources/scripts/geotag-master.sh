#!/usr/bin/env bash
set -euo pipefail

# geotag-master.sh — robust per-file version (no namerefs, no batching)

PHOTOS_ROOT="."
GPX_POOL=""
FROM_TZ=""
TO_TZ=""
DRIFT_KIND=""    # ahead|behind|exact
DRIFT_VAL=""     # 2m | 1:30m | 45s | +75s
WRITE_TIME=0
WRITE_TZ_TAGS=0
ALSO_QT=0
OVERWRITE=0
COPY_MATCHED=0
RETAG_MODE="missing"   # missing|overwrite
DRYRUN=0
VERBOSE=0

VERBOSE_SAMPLE_COUNT=3

die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'USAGE'
Usage:
  geotag-master.sh --photos PATH --pool PATH --from-tz ZONE --to-tz ZONE [options]
Time zones: IANA (Europe/Moscow) or numeric (UTC+6, +05:00, -3:30, Z, UTC)
Drift: --drift-ahead 2m | --drift-behind 30s | --drift-exact +75s
Normalize: --write-time --write-tz-tags [--also-qt]
Behavior:  --copy-matched  --retag overwrite  --overwrite  --dry-run  --verbose
USAGE
}

# -------- arg parse --------
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
    --retag) [[ "${2:-}" =~ ^(missing|overwrite)$ ]] || die "--retag must be missing|overwrite"; RETAG_MODE="$2"; shift 2;;
    --dry-run) DRYRUN=1; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

[[ -d "$PHOTOS_ROOT" ]] || die "--photos not found"
[[ -d "$GPX_POOL"   ]] || die "--pool not found"
[[ -n "$FROM_TZ"    ]] || die "--from-tz required"
[[ -n "$TO_TZ"      ]] || die "--to-tz required"

trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

parse_tz_to_seconds(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}"
    ((10#$hh<=14)) || die "Hour out of range: $z"
    local secs=$((10#$hh*3600)); [[ $sign == "-" ]] && secs=$((-secs)); echo "$secs"; return
  elif [[ "$z" =~ ^([+-])([0-9]{1,2}):([0-9]{2})$ ]]; then
    local sign="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
    ((10#$hh<=14)) || die "Hour out of range: $z"; ((10#$mm<=59)) || die "Minute out of range: $z"
    local secs=$((10#$hh*3600 + 10#$mm*60)); [[ $sign == "-" ]] && secs=$((-secs)); echo "$secs"; return
  fi
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown time zone: $z"
  local s; s="$(TZ="$z" date +%z)"; local sign="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60)); [[ $sign == "-" ]] && secs=$((-secs)); echo "$secs"
}

pad_hms(){  # input seconds -> +HH:MM:SS
  local s=$1 sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$((-s))
  printf "%s%02d:%02d:%02d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

parse_drift_abs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Unsupported drift: $v"; fi
}
parse_drift_exact(){
  local v="$1" sign="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sign="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi
  local a; a="$(parse_drift_abs "$v")"; [[ $sign == "-" ]] && echo $((-a)) || echo "$a"
}

log(){ [[ $VERBOSE -eq 1 ]] && echo "$@" >&2 || true; }

common=(-P); [[ $OVERWRITE -eq 1 ]] && common+=(-overwrite_original)
run(){ # prints on verbose; executes unless --dry-run
  if [[ $DRYRUN -eq 1 || $VERBOSE -eq 1 ]]; then
    printf "[CMD] exiftool"; for a in "${common[@]}"; do printf " %q" "$a"; done
    while [[ $# -gt 0 ]]; do printf " %q" "$1"; shift; done; echo
    [[ $DRYRUN -eq 1 ]] && return 0
  fi
  exiftool "${common[@]}" "$@"
}

# Build params
FROM_OFFS=$(parse_tz_to_seconds "$FROM_TZ")
TO_OFFS=$(parse_tz_to_seconds "$TO_TZ")
DRIFT_SECS=0
if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
  case "$DRIFT_KIND" in
    ahead)  DRIFT_SECS=$(parse_drift_abs "$DRIFT_VAL");;
    behind) DRIFT_SECS=$(( - $(parse_drift_abs "$DRIFT_VAL") ));;
    exact)  DRIFT_SECS=$(parse_drift_exact "$DRIFT_VAL");;
    *) die "Invalid drift kind";;
  esac
fi
NET_DELTA=$(( TO_OFFS - FROM_OFFS + DRIFT_SECS ))
GEO_SYNC_LIST=( "0:0:0 $(pad_hms $FROM_OFFS)" ); [[ $DRIFT_SECS -ne 0 ]] && GEO_SYNC_LIST+=( "0:0:0 $(pad_hms $DRIFT_SECS)" )

echo "Photos root   : $PHOTOS_ROOT"
echo "GPX pool      : $GPX_POOL"
echo "Camera TZ     : $FROM_TZ (offset $(pad_hms $FROM_OFFS))"
echo "Actual TZ     : $TO_TZ   (offset $(pad_hms $TO_OFFS))"
[[ -n "$DRIFT_KIND" ]] && echo "Camera drift  : $DRIFT_KIND $DRIFT_VAL  => $(pad_hms $DRIFT_SECS)" || echo "Camera drift  : none"
echo "Geotag syncs  : ${GEO_SYNC_LIST[*]}"
echo "Rewrite times : $([[ $WRITE_TIME -eq 1 ]] && echo YES || echo NO)   (net $(pad_hms $NET_DELTA))"
echo "Write TZ tags : $([[ $WRITE_TZ_TAGS -eq 1 ]] && echo YES || echo NO)"
echo "Also QuickTime: $([[ $ALSO_QT -eq 1 ]] && echo YES || echo NO)"
echo "Retag mode    : $RETAG_MODE"
echo "Copy matched  : $([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
echo "Overwrite     : $([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
echo "Dry run       : $([[ $DRYRUN -eq 1 ]] && echo YES || echo NO)"
echo "Verbose       : $([[ $VERBOSE -eq 1 ]] && echo YES || echo NO)"
echo

list_photos_in_dir(){ # print 0-terminated paths
  find "$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0
}

show_samples(){
  [[ $VERBOSE -eq 1 ]] || return 0
  local dir="$1"
  echo "[BEFORE] sample from: $dir"
  exiftool -q -q -n -S -G1 -DateTimeOriginal -CreateDate -ModifyDate -OffsetTimeOriginal -GPSLatitude -GPSLongitude "$dir" | head -n $VERBOSE_SAMPLE_COUNT
}

show_after(){
  [[ $VERBOSE -eq 1 ]] || return 0
  local dir="$1"
  echo "[AFTER]  sample from: $dir"
  exiftool -q -q -n -S -G1 -DateTimeOriginal -CreateDate -ModifyDate -OffsetTimeOriginal -GPSLatitude -GPSLongitude "$dir" | head -n $VERBOSE_SAMPLE_COUNT
}

# ---------- Phase A: per-file time normalization ----------
if [[ $WRITE_TIME -eq 1 ]]; then
  echo "Phase A: rewriting EXIF times (per file)..."
  while IFS= read -r -d '' dir; do
    # collect files in this dir
    mapfile -d '' FILES < <(list_photos_in_dir "$dir")
    ((${#FILES[@]}==0)) && continue

    # shift times
    if [[ $NET_DELTA -ne 0 ]]; then
      abs=$(( NET_DELTA<0 ? -NET_DELTA : NET_DELTA )); shift_str="$(pad_hms $abs)"; shift_str="${shift_str#?}"
      [[ $VERBOSE -eq 1 ]] && echo "[INFO] $dir  shift AllDates by $([[ $NET_DELTA -gt 0 ]] && echo + || echo -)$shift_str"
      for f in "${FILES[@]}"; do
        if [[ $NET_DELTA -gt 0 ]]; then run "-AllDates+=${shift_str}" "$f"; else run "-AllDates-=${shift_str}" "$f"; fi
        if [[ $ALSO_QT -eq 1 ]]; then
          if [[ $NET_DELTA -gt 0 ]]; then
            run "-QuickTime:CreateDate+=${shift_str}" "-QuickTime:ModifyDate+=${shift_str}" "-QuickTime:MediaCreateDate+=${shift_str}" "-XMP:CreateDate+=${shift_str}" "$f"
          else
            run "-QuickTime:CreateDate-=${shift_str}" "-QuickTime:ModifyDate-=${shift_str}" "-QuickTime:MediaCreateDate-=${shift_str}" "-XMP:CreateDate-=${shift_str}" "$f"
          fi
        fi
      done
    fi

    # tz tags
    if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
      tz_abs=$TO_OFFS; sign="+"; [[ $tz_abs -lt 0 ]] && sign="-" && tz_abs=$((-tz_abs))
      tz=$(printf "%s%02d:%02d" "$sign" $((tz_abs/3600)) $(((tz_abs%3600)/60)))
      [[ $VERBOSE -eq 1 ]] && echo "[INFO] $dir  write OffsetTime* = $tz"
      for f in "${FILES[@]}"; do
        run "-OffsetTimeOriginal=$tz" "-OffsetTime=$tz" "-OffsetTimeDigitized=$tz" "$f"
      done
    fi
  done < <(find "$PHOTOS_ROOT" -type d -print0)
fi

# ---------- Phase B: geotagging ----------
echo "Phase B: geotagging per folder..."
while IFS= read -r -d '' dir; do
  show_samples "$dir"

  # collect files
  mapfile -d '' FILES < <(list_photos_in_dir "$dir")
  ((${#FILES[@]}==0)) && { [[ $VERBOSE -eq 1 ]] && echo "[INFO] $dir (no photo files)"; continue; }

  # local GPX first
  shopt -s nullglob; local_gpx=( "$dir"/*.gpx "$dir"/*.GPX ); shopt -u nullglob
  if ((${#local_gpx[@]}>0)); then
    for f in "${FILES[@]}"; do
      if [[ "$RETAG_MODE" == "missing" ]]; then run -geosync "${GEO_SYNC_LIST[0]}" ${GEO_SYNC_LIST[1]+-geosync "${GEO_SYNC_LIST[1]}"} -geotag "$dir" -if 'not $gpslatitude' "$f"
      else run -geosync "${GEO_SYNC_LIST[0]}" ${GEO_SYNC_LIST[1]+-geosync "${GEO_SYNC_LIST[1]}"} -geotag "$dir" "$f"; fi
    done
  fi

  # pool GPX for remaining untagged
  missing=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "${FILES[@]}" | wc -l | tr -d ' ')
  if (( missing > 0 )); then
    shopt -s nullglob; pool=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX ); shopt -u nullglob
    for gpx in "${pool[@]:-}"; do
      before=$missing
      for f in "${FILES[@]}"; do
        if [[ "$RETAG_MODE" == "missing" ]]; then run -geosync "${GEO_SYNC_LIST[0]}" ${GEO_SYNC_LIST[1]+-geosync "${GEO_SYNC_LIST[1]}"} -geotag "$gpx" -if 'not $gpslatitude' "$f"
        else run -geosync "${GEO_SYNC_LIST[0]}" ${GEO_SYNC_LIST[1]+-geosync "${GEO_SYNC_LIST[1]}"} -geotag "$gpx" "$f"; fi
      done
      missing=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "${FILES[@]}" | wc -l | tr -d ' ')
      updated=$(( before - missing ))
      if (( updated > 0 )); then
        echo "  [+] $(basename "$gpx") matched $dir (updated $updated files)"
        if (( COPY_MATCHED==1 && DRYRUN==0 )); then
          base="$(basename "$gpx")"; dst="$dir/$base"
          if [[ -e "$dst" ]]; then n=1; while [[ -e "$dir/${base%.*}_$n.${base##*.}" ]]; do n=$((n+1)); done; dst="$dir/${base%.*}_$n.${base##*.}"; fi
          cp -n "$gpx" "$dst" || true
        fi
      fi
      (( missing <= 0 )) && break
    done
  fi

  show_after "$dir"
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Done."
echo "Check a few files:"
echo "  exiftool -n -GPSLatitude -GPSLongitude -DateTimeOriginal -OffsetTimeOriginal -S -r \"$PHOTOS_ROOT\" | head -80"
