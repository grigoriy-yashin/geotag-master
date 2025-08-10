#!/usr/bin/env bash
set -euo pipefail

# geotag-min.sh — do it the simple, robust way (per-folder, quoted args)

PHOTOS_ROOT="."
GPX_POOL=""
FROM_TZ=""
TO_TZ=""
DRIFT_KIND=""   # ahead|behind|exact
DRIFT_VAL=""

WRITE_TIME=0
WRITE_TZ_TAGS=0
RETAG_MODE="missing"  # missing|overwrite
COPY_MATCHED=0
OVERWRITE=0
VERBOSE=0
ALSO_QT=0   # optional: shift QuickTime/XMP too

die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'H'
Usage:
  geotag-min.sh --photos DIR --pool DIR --from-tz ZONE --to-tz ZONE [options]

Zones:  Europe/Moscow  Asia/Almaty  UTC+6  +05:00  -3:30  Z  UTC
Drift:  --drift-ahead 2m | --drift-behind 30s | --drift-exact +75s
Flags:  --write-time --write-tz-tags [--also-qt] --retag overwrite --copy-matched --overwrite --verbose
H
}

# ---------- args ----------
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
    --retag) [[ "${2:-}" =~ ^(missing|overwrite)$ ]] || die "--retag missing|overwrite"; RETAG_MODE="$2"; shift 2;;
    --copy-matched) COPY_MATCHED=1; shift;;
    --overwrite) OVERWRITE=1; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -d "$PHOTOS_ROOT" ]] || die "--photos not found"
[[ -d "$GPX_POOL"   ]] || die "--pool not found"
[[ -n "$FROM_TZ" ]] || die "--from-tz required"
[[ -n "$TO_TZ"   ]] || die "--to-tz required"

# ---------- helpers ----------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }
parse_tz_to_seconds(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASHREMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})$ ]]; then
    local sgn="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}"; ((10#$hh<=14)) || die "TZ hour $z"
    local secs=$((10#$hh*3600)); [[ $sgn == "-" ]] && secs=$((-secs)); echo "$secs"; return
  elif [[ "$z" =~ ^([+-])([0-9]{1,2}):([0-9]{2})$ ]]; then
    local sgn="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]}"
    ((10#$hh<=14)) || die "TZ hour $z"; ((10#$mm<=59)) || die "TZ min $z"
    local secs=$((10#$hh*3600 + 10#$mm*60)); [[ $sgn == "-" ]] && secs=$((-secs)); echo "$secs"; return
  fi
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown TZ: $z"
  local s; s="$(TZ="$z" date +%z)"; local sgn="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60)); [[ $sgn == "-" ]] && secs=$((-secs)); echo "$secs"
}
pad_hms(){ local s=$1; local sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$((-s)); printf "%s%02d:%02d:%02d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60)); }

parse_drift_abs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Bad drift '$v'"; fi
}
parse_drift_exact(){ local v="$1" sign="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sign="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi; local a; a="$(parse_drift_abs "$v")"; [[ $sign == "-" ]] && echo $((-a)) || echo "$a"; }

# ---------- calc ----------
FROM_OFFS=$(parse_tz_to_seconds "$FROM_TZ")
TO_OFFS=$(parse_tz_to_seconds "$TO_TZ")
DRIFT_SECS=0
case "$DRIFT_KIND" in
  ahead)  [[ -n "$DRIFT_VAL" ]] && DRIFT_SECS=$(parse_drift_abs "$DRIFT_VAL");;
  behind) [[ -n "$DRIFT_VAL" ]] && DRIFT_SECS=$(( - $(parse_drift_abs "$DRIFT_VAL") ));;
  exact)  [[ -n "$DRIFT_VAL" ]] && DRIFT_SECS=$(parse_drift_exact "$DRIFT_VAL");;
  "" ) :;;
  * ) die "drift kind must be ahead|behind|exact";;
esac

NET_DELTA=$(( TO_OFFS - FROM_OFFS + DRIFT_SECS ))
GEO_SHIFT=$(( FROM_OFFS + DRIFT_SECS ))

# ---------- summary ----------
echo "Photos root   : $PHOTOS_ROOT"
echo "GPX pool      : $GPX_POOL"
echo "Camera TZ     : $FROM_TZ (offset $(pad_hms $FROM_OFFS))"
echo "Actual TZ     : $TO_TZ   (offset $(pad_hms $TO_OFFS))"
[[ -n "$DRIFT_KIND" ]] && echo "Camera drift  : $DRIFT_KIND $DRIFT_VAL  => $(pad_hms $DRIFT_SECS)" || echo "Camera drift  : none"
echo "Geotag sync   : $(pad_hms $GEO_SHIFT)"
echo "Rewrite times : $([[ $WRITE_TIME -eq 1 ]] && echo YES || echo NO)   (net $(pad_hms $NET_DELTA))"
echo "Write TZ tags : $([[ $WRITE_TZ_TAGS -eq 1 ]] && echo YES || echo NO)"
echo "Retag mode    : $RETAG_MODE"
echo "Copy matched  : $([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
echo "Overwrite     : $([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
echo "Verbose       : $([[ $VERBOSE -eq 1 ]] && echo YES || echo NO)"
echo

# ---------- run helpers ----------
xt_common=(-P); [[ $OVERWRITE -eq 1 ]] && xt_common+=(-overwrite_original)
xt(){  # print then run
  if [[ $VERBOSE -eq 1 ]]; then printf "[CMD] exiftool"; for a in "${xt_common[@]}"; do printf " %q" "$a"; done; while [[ $# -gt 0 ]]; do printf " %q" "$1"; shift; done; echo; fi
  exiftool "${xt_common[@]}" "$@"
}

# ---------- Phase A: per-folder time & tz tags (using globs; QUOTED args) ----------
if [[ $WRITE_TIME -eq 1 || $WRITE_TZ_TAGS -eq 1 ]]; then
  echo "Phase A: time / tz tags..."
  while IFS= read -r -d '' dir; do
    shopt -s nullglob
    files=( "$dir"/*.JPG "$dir"/*.jpg "$dir"/*.JPEG "$dir"/*.jpeg "$dir"/*.ORF" " $dir"/*.orf "$dir"/*.RW2 "$dir"/*.rw2 "$dir"/*.ARW "$dir"/*.arw "$dir"/*.CR2 "$dir"/*.cr2 "$dir"/*.DNG "$dir"/*.dng "$dir"/*.NEF "$dir"/*.nef "$dir"/*.HEIC "$dir"/*.heic "$dir"/*.HEIF "$dir"/*.heif "$dir"/*.TIF "$dir"/*.tif "$dir"/*.TIFF "$dir"/*.tiff )
    shopt -u nullglob
    (( ${#files[@]} == 0 )) && continue

    if [[ $WRITE_TIME -eq 1 && $NET_DELTA -ne 0 ]]; then
      abs=$(( NET_DELTA<0 ? -NET_DELTA : NET_DELTA ))
      shift_str="$(pad_hms $abs)"; shift_str="${shift_str#?}"  # HH:MM:SS
      if [[ $NET_DELTA -gt 0 ]]; then
        xt "-DateTimeOriginal+=${shift_str}" "-CreateDate+=${shift_str}" "-ModifyDate+=${shift_str}" "${files[@]}"
        [[ $ALSO_QT -eq 1 ]] && xt "-QuickTime:CreateDate+=${shift_str}" "-QuickTime:ModifyDate+=${shift_str}" "-QuickTime:MediaCreateDate+=${shift_str}" "-XMP:CreateDate+=${shift_str}" "${files[@]}"
      else
        xt "-DateTimeOriginal-=${shift_str}" "-CreateDate-=${shift_str}" "-ModifyDate-=${shift_str}" "${files[@]}"
        [[ $ALSO_QT -eq 1 ]] && xt "-QuickTime:CreateDate-=${shift_str}" "-QuickTime:ModifyDate-=${shift_str}" "-QuickTime:MediaCreateDate-=${shift_str}" "-XMP:CreateDate-=${shift_str}" "${files[@]}"
      fi
    fi

    if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
      tz_abs=$TO_OFFS; sign="+"; [[ $tz_abs -lt 0 ]] && sign="-" && tz_abs=$((-tz_abs))
      tz=$(printf "%s%02d:%02d" "$sign" $((tz_abs/3600)) $(((tz_abs%3600)/60)))
      xt "-OffsetTimeOriginal=${tz}" "-OffsetTime=${tz}" "-OffsetTimeDigitized=${tz}" "${files[@]}"
    fi
  done < <(find "$PHOTOS_ROOT" -type d -print0)
fi

# ---------- Phase B: geotagging (local first, then pool), QUOTED -geosync ----------
echo "Phase B: geotagging..."
geo_shift="$(pad_hms $GEO_SHIFT)"
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  files=( "$dir"/*.JPG "$dir"/*.jpg "$dir"/*.JPEG "$dir"/*.jpeg "$dir"/*.ORF "$dir"/*.orf "$dir"/*.RW2 "$dir"/*.rw2 "$dir"/*.ARW "$dir"/*.arw "$dir"/*.CR2 "$dir"/*.cr2 "$dir"/*.DNG "$dir"/*.dng "$dir"/*.NEF "$dir"/*.nef "$dir"/*.HEIC "$dir"/*.heic "$dir"/*.HEIF "$dir"/*.heif "$dir"/*.TIF "$dir"/*.tif "$dir"/*.TIFF "$dir"/*.tiff )
  loc=( "$dir"/*.gpx "$dir"/*.GPX )
  shopt -u nullglob
  (( ${#files[@]} == 0 )) && continue

  # local GPX
  if (( ${#loc[@]} > 0 )); then
    if [[ "$RETAG_MODE" == "missing" ]]; then
      xt "-geosync=${geo_shift}" -geotag "$dir" -if 'not $gpslatitude' "${files[@]}"
    else
      xt "-geosync=${geo_shift}" -geotag "$dir" "${files[@]}"
    fi
  fi

  # pool GPX
  shopt -s nullglob; pool=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX ); shopt -u nullglob
  if (( ${#pool[@]} > 0 )); then
    before=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "${files[@]}" | wc -l | tr -d ' ')
    for g in "${pool[@]}"; do
      if [[ "$RETAG_MODE" == "missing" ]]; then
        xt "-geosync=${geo_shift}" -geotag "$g" -if 'not $gpslatitude' "${files[@]}"
      else
        xt "-geosync=${geo_shift}" -geotag "$g" "${files[@]}"
      fi
      after=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "${files[@]}" | wc -l | tr -d ' ')
      updated=$(( before - after ))
      if (( updated > 0 )); then
        echo "  [+] $(basename "$g") -> $dir  (updated $updated)"
        if (( COPY_MATCHED==1 )); then
          dst="$dir/$(basename "$g")"; if [[ -e "$dst" ]]; then n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done; dst="${dst%.*}_$n.${dst##*.}"; fi
          cp -n "$g" "$dst" || true
        fi
        before=$after
        (( after == 0 )) && break
      fi
    done
  fi
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Done."
echo "Quick check:"
echo "  exiftool -n -GPSLatitude -GPSLongitude -DateTimeOriginal -OffsetTimeOriginal -S -r \"$PHOTOS_ROOT\" | head -80"
