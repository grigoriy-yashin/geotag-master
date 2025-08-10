#!/usr/bin/env bash
set -euo pipefail

# Fast geotag-master.sh — batch exiftool calls per folder
# Linux + exiftool + GNU date required

PHOTOS_ROOT="."
GPX_POOL=""
FROM_TZ=""
TO_TZ=""
TZ_TAG=""            # +HH:MM to write OffsetTime*, or to force geotime TZ
DRIFT_KIND=""        # ahead|behind
DRIFT_VAL=""         # 3m|45s|1:30m  (no +/- signs)
GEOTAG_ONLY=0
COPY_MATCHED=0
OVERWRITE=1
VERBOSE=0
DRYRUN=0
MAX_EXT_SECS=0       # seconds extension when comparing photo time vs GPX span

die(){ echo "Error: $*" >&2; exit 1; }
msg(){ echo "$*"; }

usage(){
cat <<'EOF'
Usage:
  geotag-master.sh --photos DIR [--pool DIR]
                   [--from-tz Z --to-tz Z [--drift-ahead V | --drift-behind V]]
                   [--tz-tag +HH:MM]
                   [--geotag-only]
                   [--copy-matched] [--no-overwrite]
                   [--max-ext SECS] [--verbose] [--dry-run]

Z (timezone): UTC+3, +03:00, +3, -04:30, UTC, Z
Drift V:      3m, 45s, 1:30m  (pick ahead/behind; no +/-)

How it works (fast path)
------------------------
Per photo folder:
  1) (Default mode only) Compute NET = (to − from) − ahead + behind, then shift all
     DateTimeOriginal/CreateDate/ModifyDate in one exiftool call; write OffsetTime* in one call.
  2) Geotag:
     - Build geotime: -geotime<${DateTimeOriginal}+TZ>. TZ = --tz-tag or --to-tz
       (in --geotag-only mode, if neither is set, it uses file's OffsetTimeOriginal).
     - Apply ALL local GPX (folder *.gpx) in one call (idempotent).
     - Pick pool GPX whose <time> span overlaps this folder's photo time range (± --max-ext),
       and apply each of them in one call.
     - If a pool GPX updated any files and --copy-matched is set, copy that GPX into the folder.

Examples
--------
# Olympus case (normalize + geotag)
geotag-master.sh \
  --photos /data/2025-07-28 \
  --pool /data/Downloads \
  --from-tz UTC+3 --to-tz UTC+5 --drift-ahead 3m \
  --tz-tag +05:00 --copy-matched --verbose

# Phone photos (times already correct): geotag only
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
if [[ -n "$GPX_POOL" ]]; then [[ -d "$GPX_POOL" ]] || die "--pool not found"; GPX_POOL="${GPX_POOL%/}"; fi

# ---------------- helpers ----------------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }
tz_to_secs(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "UTC" || "$z" == "utc" || "$z" == "Z" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(:([0-9]{1,2}))?$ ]]; then
    local s="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" m="${BASH_REMATCH[4]:-0}"
    ((10#$h<=14)) || die "TZ hour out of range: $z"
    ((10#$m<=59)) || die "TZ minute out of range: $z"
    local t=$((10#$h*3600 + 10#$m*60)); [[ $s == "-" ]] && t=$((-t)); echo "$t"; return
  fi
  die "unsupported TZ '$1' (use numeric offset: UTC+5, +05:00, +5, -04:30, UTC, Z)"
}
secs_to_hms_signed(){ local s="$1" sign="+"; [[ $s -lt 0 ]] && sign="-" && s=$((-s)); printf "%s%d:%d:%d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60)); }
secs_to_hms_abs(){ local s="$1"; [[ $s -lt 0 ]] && s=$((-s)); printf "%d:%d:%d" $((s/3600)) $(((s%3600)/60)) $((s%60)); }
drift_to_secs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( 10#${BASH_REMATCH[1]}*60 + 10#${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then         echo $(( 10#${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([0-9]+)s$ ]]; then         echo $(( 10#${BASH_REMATCH[1]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then          echo $(( 10#$v ))
  else die "Bad drift '$v' (use 3m, 45s, 1:30m)"; fi
}

# Build and run exiftool with an argfile; accepts options then files after "--"
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
  if [[ $VERBOSE -eq 1 ]]; then echo "[ARGFILE]"; sed 's/^/  /' "$tmp"; fi
  if [[ $DRYRUN -eq 1 ]]; then rm -f "$tmp"; return 0; fi
  exiftool -@ "$tmp"
  rm -f "$tmp"
}

# Same as et() but capture output to a variable
et_capture(){
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
  if [[ $DRYRUN -eq 1 ]]; then rm -f "$tmp"; return 0; fi
  exiftool -@ "$tmp"; local rc=$?
  rm -f "$tmp"; return $rc
}

# Read all image files in a dir (one level), case-insensitive extensions
list_dir_images(){
  find "$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0
}

# Compute folder's photo time range (UTC epoch min/max) using a single exiftool call
folder_time_range(){
  local dir="$1" tz="$2"
  # get DTO and OffsetTimeOriginal per file (tab-separated)
  local out
  out="$(exiftool -q -q -n -T -DateTimeOriginal -OffsetTimeOriginal -- \
          $(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print) \
        || true)"
  [[ -z "$out" ]] && return 1
  local min= INF=9999999999 max=0
  min=$INF
  while IFS=$'\t' read -r dto otz; do
    [[ -z "$dto" ]] && continue
    local iso="${dto/:/-}"; iso="${iso/:/-}"
    local use_tz="$tz"
    [[ -z "$use_tz" ]] && use_tz="$otz"
    [[ -z "$use_tz" ]] && continue
    local epoch
    epoch="$(date -ud "$iso $use_tz" +%s 2>/dev/null || true)"
    [[ -z "$epoch" ]] && continue
    (( epoch < min )) && min=$epoch
    (( epoch > max )) && max=$epoch
  done <<<"$out"
  [[ $min -eq $INF ]] && return 1
  echo "$min $max"
}

# GPX first/last <time> (UTC epoch)
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

sum_updated_from_output(){
  # sum numbers from lines like "N image files updated" or "N image files created"
  awk '/image files (updated|created)/{s+=$1} END{print s+0}'
}

# ---------------- compute shift / tz strings ----------------
MATCH_TZ_STR=""
NET_SIGN="" ; NET_ABS=""

if [[ $GEOTAG_ONLY -eq 1 ]]; then
  if [[ -n "$TZ_TAG" ]]; then
    MATCH_TZ_STR="$TZ_TAG"
  elif [[ -n "$TO_TZ" ]]; then
    toS=$(tz_to_secs "$TO_TZ"); s="+"; [[ $toS -lt 0 ]] && s="-" && toS=$((-toS))
    MATCH_TZ_STR=$(printf "%s%02d:%02d" "$s" $((toS/3600)) $(((toS%3600)/60)))
  else
    MATCH_TZ_STR=""  # will fall back to file OffsetTimeOriginal during range calc; geotime still needs TZ per file (OffsetTimeOriginal)
  fi
else
  [[ -n "$FROM_TZ" && -n "$TO_TZ" ]] || die "--from-tz and --to-tz required unless --geotag-only"
  fromS=$(tz_to_secs "$FROM_TZ"); toS=$(tz_to_secs "$TO_TZ")
  net=$(( toS - fromS ))
  if [[ -n "$DRIFT_KIND" && -n "$DRIFT_VAL" ]]; then
    d=$(drift_to_secs "$DRIFT_VAL")
    [[ "$DRIFT_KIND" == "ahead"  ]] && net=$(( net - d ))
    [[ "$DRIFT_KIND" == "behind" ]] && net=$(( net + d ))
  fi
  NET_SIGN=$(secs_to_hms_signed "$net")
  NET_ABS=$(secs_to_hms_abs "$net")
  # TZ used for tags + geotime
  toAbs=$toS; tsgn="+"; [[ $toAbs -lt 0 ]] && tsgn="-" && toAbs=$((-toAbs))
  MATCH_TZ_STR=$(printf "%s%02d:%02d" "$tsgn" $((toAbs/3600)) $(((toAbs%3600)/60)))
  [[ -n "$TZ_TAG" ]] && MATCH_TZ_STR="$TZ_TAG"
  [[ "$MATCH_TZ_STR" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "bad --tz-tag/--to-tz offset (need +HH:MM)"
fi

# ---------------- walk folders ----------------
export LC_ALL=C
while IFS= read -r -d '' dir; do
  # collect files
  mapfile -d '' files < <(list_dir_images "$dir")
  (( ${#files[@]} == 0 )) && continue

  # Phase 1: batch shift + tz tags (unless geotag-only)
  if [[ $GEOTAG_ONLY -eq 0 ]]; then
    if [[ "$NET_SIGN" != "+0:0:0" && "$NET_SIGN" != "-0:0:0" ]]; then
      if [[ "${NET_SIGN:0:1}" == "-" ]]; then
        et "-DateTimeOriginal-=${NET_ABS}" "-CreateDate-=${NET_ABS}" "-ModifyDate-=${NET_ABS}" -- "${files[@]}"
      else
        et "-DateTimeOriginal+=${NET_ABS}" "-CreateDate+=${NET_ABS}" "-ModifyDate+=${NET_ABS}" -- "${files[@]}"
      fi
    fi
    # write tz tags once for all files
    et "-OffsetTimeOriginal=${MATCH_TZ_STR}" "-OffsetTime=${MATCH_TZ_STR}" "-OffsetTimeDigitized=${MATCH_TZ_STR}" -- "${files[@]}"
  fi

  # Geotag: local GPX first (apply all), then pool GPX (prefiltered)
  # Build geotime arg. In geotag-only w/o tz-tag/to-tz, we still need a TZ:
  # exiftool allows -geotime<${DateTimeOriginal}+OffsetTimeOriginal>, but that’s per-file.
  # For batch, we choose:
  geotime=""
  if [[ -n "$MATCH_TZ_STR" ]]; then
    geotime="-geotime<\${DateTimeOriginal}${MATCH_TZ_STR}>"
  else
    # per-file fallback: use +OffsetTimeOriginal
    geotime="-geotime<\${DateTimeOriginal}+\${OffsetTimeOriginal}>"
  fi

  msg "Geotagging: $dir"

  # Local GPX (no prefilter; idempotent)
  shopt -s nullglob
  local_gpx=( "$dir"/*.gpx "$dir"/*.GPX )
  shopt -u nullglob
  if (( ${#local_gpx[@]} )); then
    et "$geotime" -geotag "$dir" -- "${files[@]}" || true
  fi

  # Pool GPX (prefilter by folder time range)
  if [[ -n "$GPX_POOL" ]]; then
    # compute folder UTC range (using MATCH_TZ_STR or file OffsetTimeOriginal)
    folder_minmax="$(folder_time_range "$dir" "${MATCH_TZ_STR}")" || folder_minmax=""
    pool_to_try=()
    if [[ -n "$folder_minmax" ]]; then
      fmin=$(awk '{print $1}' <<<"$folder_minmax"); fmax=$(awk '{print $2}' <<<"$folder_minmax")
      as=$fmin; ae=$fmax
      (( MAX_EXT_SECS > 0 )) && { as=$((fmin-MAX_EXT_SECS)); ae=$((fmax+MAX_EXT_SECS)); }
      shopt -s nullglob
      for g in "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX; do
        span="$(gpx_span_epoch "$g" || true)" || continue
        gs=$(awk '{print $1}' <<<"$span"); ge=$(awk '{print $2}' <<<"$span")
        # overlap if not (ge<as or gs>ae)
        if ! (( ge < as || gs > ae )); then
          pool_to_try+=( "$g" )
        else
          [[ $VERBOSE -eq 1 ]] && echo "[skip GPX] $(basename "$g") (outside folder range)"
        fi
      done
      shopt -u nullglob
    else
      # couldn't compute range → try all pool GPX (rare)
      shopt -s nullglob; pool_to_try=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX ); shopt -u nullglob
    fi

    # Apply each selected pool GPX once; copy if it updated anything
    for g in "${pool_to_try[@]:-}"; do
      out="$(et_capture "$geotime" -geotag "$g" -- "${files[@]}" 2>&1 || true)"
      updated=$(printf "%s\n" "$out" | sum_updated_from_output)
      if (( COPY_MATCHED==1 && DRYRUN==0 && updated>0 )); then
        dst="$dir/$(basename "$g")"
        if [[ -e "$dst" ]]; then
          n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done
          dst="${dst%.*}_$n.${dst##*.}"
        fi
        cp "$g" "$dst" || true
      fi
      [[ $VERBOSE -eq 1 ]] && printf "[%s] %s -> %d updated\n" "$(basename "$dir")" "$(basename "$g")" "$updated"
    done
  fi

done < <(find "$PHOTOS_ROOT" -type d -print0)

msg "Done."
