#!/usr/bin/env bash
set -euo pipefail

# geotag-solid.sh — per-file, exiftool-compatible (matches your working CLI)

PHOTOS_ROOT="."
GPX_POOL=""
FROM_TZ=""
TO_TZ=""
DRIFT_KIND=""    # ahead|behind|exact
DRIFT_VAL=""     # 2m | 1:30m | 45s | +75s

WRITE_TIME=0
WRITE_TZ_TAGS=0
RETAG_MODE="missing"   # missing|overwrite
COPY_MATCHED=0
OVERWRITE=0
VERBOSE=0
ALSO_QT=0

die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'H'
Usage:
  geotag-solid.sh --photos DIR --pool DIR --from-tz ZONE --to-tz ZONE [options]

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

# normalize paths (strip trailing slash)
PHOTOS_ROOT="${PHOTOS_ROOT%/}"
GPX_POOL="${GPX_POOL%/}"

[[ -d "$PHOTOS_ROOT" ]] || die "--photos not found"
[[ -d "$GPX_POOL"   ]] || die "--pool not found"
[[ -n "$FROM_TZ" ]] || die "--from-tz required"
[[ -n "$TO_TZ"   ]] || die "--to-tz required"

trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

parse_tz_to_seconds(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
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

# padded H:MM:SS with sign (ExifTool accepts both padded/non-padded; this is clean)
secs_to_hms(){
  local s=$1 sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$((-s))
  printf "%s%02d:%02d:%02d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

parse_drift_abs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Bad drift '$v'"; fi
}
parse_drift_exact(){
  local v="$1" sign="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sign="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi
  local a; a="$(parse_drift_abs "$v")"; [[ $sign == "-" ]] && echo $((-a)) || echo "$a"
}

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

printf "Photos root   : %s\n" "$PHOTOS_ROOT"
printf "GPX pool      : %s\n" "$GPX_POOL"
printf "Camera TZ     : %s (offset %s)\n" "$FROM_TZ" "$(secs_to_hms "$FROM_OFFS")"
printf "Actual TZ     : %s   (offset %s)\n" "$TO_OFFS" "$(secs_to_hms "$TO_OFFS")"
if [[ -n "$DRIFT_KIND" ]]; then
  printf "Camera drift  : %s %s  => %s\n" "$DRIFT_KIND" "$DRIFT_VAL" "$(secs_to_hms "$DRIFT_SECS")"
else
  echo "Camera drift  : none"
fi
printf "Geotag sync   : %s\n" "$(secs_to_hms "$GEO_SHIFT")"
printf "Rewrite times : %s   (net %s)\n" "$([[ $WRITE_TIME -eq 1 ]] && echo YES || echo NO)" "$(secs_to_hms "$NET_DELTA")"
printf "Write TZ tags : %s\n" "$([[ $WRITE_TZ_TAGS -eq 1 ]] && echo YES || echo NO)"
printf "Retag mode    : %s\n" "$RETAG_MODE"
printf "Copy matched  : %s\n" "$([[ $COPY_MATCHED -eq 1 ]] && echo YES || echo NO)"
printf "Overwrite     : %s\n" "$([[ $OVERWRITE -eq 1 ]] && echo YES || echo NO)"
printf "Verbose       : %s\n" "$([[ $VERBOSE -eq 1 ]] && echo YES || echo NO)"
echo

xt_common=(-P); [[ $OVERWRITE -eq 1 ]] && xt_common+=(-overwrite_original)
xt(){ if [[ $VERBOSE -eq 1 ]]; then printf "[CMD] exiftool"; for a in "${xt_common[@]}"; do printf " %q" "$a"; done; while [[ $# -gt 0 ]]; do printf " %q" "$1"; shift; done; echo; fi; exiftool "${xt_common[@]}" "$@"; }

# ---------- Phase A: time / tz (per-file, exactly like your working line) ----------
if [[ $WRITE_TIME -eq 1 || $WRITE_TZ_TAGS -eq 1 ]]; then
  echo "Phase A: time / tz tags..."
  while IFS= read -r -d '' dir; do
    # list files case-insensitively, non-recursive
    while IFS= read -r -d '' f; do
      if [[ $WRITE_TIME -eq 1 && $NET_DELTA -ne 0 ]]; then
        abs=$(( NET_DELTA<0 ? -NET_DELTA : NET_DELTA ))
        shift_str="$(secs_to_hms "$abs")"; shift_str="${shift_str#?}"  # HH:MM:SS (no sign)
        if [[ $NET_DELTA -gt 0 ]]; then
          xt "-DateTimeOriginal+=${shift_str}" "-CreateDate+=${shift_str}" "-ModifyDate+=${shift_str}" "$f"
          [[ $ALSO_QT -eq 1 ]] && xt "-QuickTime:CreateDate+=${shift_str}" "-QuickTime:ModifyDate+=${shift_str}" "-QuickTime:MediaCreateDate+=${shift_str}" "-XMP:CreateDate+=${shift_str}" "$f"
        else
          xt "-DateTimeOriginal-=${shift_str}" "-CreateDate-=${shift_str}" "-ModifyDate-=${shift_str}" "$f"
          [[ $ALSO_QT -eq 1 ]] && xt "-QuickTime:CreateDate-=${shift_str}" "-QuickTime:ModifyDate-=${shift_str}" "-QuickTime:MediaCreateDate-=${shift_str}" "-XMP:CreateDate-=${shift_str}" "$f"
        fi
      fi
      if [[ $WRITE_TZ_TAGS -eq 1 ]]; then
        tz_abs=$TO_OFFS; sign="+"; [[ $tz_abs -lt 0 ]] && sign="-" && tz_abs=$((-tz_abs))
        tz=$(printf "%s%02d:%02d" "$sign" $((tz_abs/3600)) $(((tz_abs%3600)/60)))
        xt "-OffsetTimeOriginal=${tz}" "-OffsetTime=${tz}" "-OffsetTimeDigitized=${tz}" "$f"
      fi
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0)
  done < <(find "$PHOTOS_ROOT" -type d -print0)
fi

# ---------- Phase B: geotag (local GPX first, then pool) ----------
echo "Phase B: geotagging..."
geo_shift="$(secs_to_hms "$GEO_SHIFT")"
while IFS= read -r -d '' dir; do
  # local GPX
  shopt -s nullglob
  local_gpx=( "$dir"/*.gpx "$dir"/*.GPX )
  pool_gpx=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX )
  shopt -u nullglob

  # per-file, like your working style
  while IFS= read -r -d '' f; do
    if (( ${#local_gpx[@]} )); then
      if [[ "$RETAG_MODE" == "missing" ]]; then
        xt "-geosync=${geo_shift}" -geotag "$dir" -if 'not $gpslatitude' "$f"
      else
        xt "-geosync=${geo_shift}" -geotag "$dir" "$f"
      fi
    fi
    # pool fallback
    if (( ${#pool_gpx[@]} )); then
      for g in "${pool_gpx[@]}"; do
        before=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$f" | wc -l | tr -d ' ')
        if [[ "$RETAG_MODE" == "missing" ]]; then
          xt "-geosync=${geo_shift}" -geotag "$g" -if 'not $gpslatitude' "$f"
        else
          xt "-geosync=${geo_shift}" -geotag "$g" "$f"
        fi
        after=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$f" | wc -l | tr -d ' ')
        if (( before>0 && after==0 )); then
          # this GPX tagged this file
          if (( COPY_MATCHED==1 )); then
            dst="$dir/$(basename "$g")"
            if [[ -e "$dst" ]]; then n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done; dst="${dst%.*}_$n.${dst##*.}"; fi
            cp -n "$g" "$dst" || true
          fi
          break
        fi
      done
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0)
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Done."
echo "Quick check:"
echo "  exiftool -n -GPSLatitude -GPSLongitude -DateTimeOriginal -OffsetTimeOriginal -S -r \"$PHOTOS_ROOT\" | head -80"
