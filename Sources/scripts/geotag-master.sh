#!/usr/bin/env bash
set -euo pipefail

# geotag-final.sh — simple, robust, and matches proven-good exiftool usage
# All exiftool writes go via an argfile (-@) to avoid shell quoting issues.

PHOTOS_ROOT="."
GPX_POOL=""

FROM_TZ=""       # e.g. UTC+3, +03:00, Europe/Moscow (IANA works too)
TO_TZ=""         # e.g. UTC+5, +05:00, Asia/Almaty

DRIFT_KIND=""    # ahead|behind|exact
DRIFT_VAL=""     # 3m | 45s | 1:30m | +75s (only exact accepts sign)

SHIFT_EXPLICIT=""    # ±H:M:S  (overrides FROM/TO/DRIFT math if set)
TZ_TAG=""            # ±HH:MM  writes OffsetTime*, does not change time-of-day

COPY_MATCHED=0
OVERWRITE=1
VERBOSE=0
DRYRUN=0
MAX_EXT_SECS=0       # allow matching beyond track ends, e.g. 300 (5 min)

die(){ echo "Error: $*" >&2; exit 1; }

usage(){
cat <<'H'
Usage (most common, two phases in one run):
  geotag-final.sh --photos DIR --pool DIR \
    --from-tz UTC+3 --to-tz UTC+5 --drift-ahead 3m \
    --tz-tag +05:00 \
    --copy-matched --verbose

Meaning:
  • First it rewrites capture times by the NET shift:
      net = (to − from) − ahead + behind
    With UTC+3 -> UTC+5 and camera ahead 3m, net = +1:57:00.
  • Then it geotags using:
      -geotime<${DateTimeOriginal}+TZ>  (TZ from --to-tz or --tz-tag)
      and no additional geosync (drift already applied in the rewrite).

Options:
  --photos DIR        Root with photos (processed recursively by folder)
  --pool DIR          Folder with GPX; used if a photo folder lacks its own GPX
  --from-tz Z         Camera timezone at shoot (UTC+3, +03:00, Europe/Moscow)
  --to-tz Z           Actual timezone you want in EXIF/iNat (UTC+5, +05:00, Asia/Almaty)
  --drift-ahead V     Camera clock runs fast by V (e.g. 3m, 45s, 1:30m)
  --drift-behind V    Camera clock runs slow by V
  --drift-exact ±S    Explicit signed seconds or H:M:S, if you insist

  --shift ±H:M:S      Explicit time rewrite; overrides any from/to/drift math
  --tz-tag ±HH:MM     Write OffsetTimeOriginal/OffsetTime/OffsetTimeDigitized

  --copy-matched      Copy any matching pool GPX into the tagged folder
  --no-overwrite      Keep _original backups (default is overwrite)
  --max-ext SECS      Allow matching beyond track ends, e.g. 300
  --verbose           Print commands and small results
  --dry-run           Show what would run; make no changes

Examples:
  # A) Full flow: UTC+3 camera, actual UTC+5, camera ahead 3m
  geotag-final.sh --photos /p --pool /gpx \
    --from-tz UTC+3 --to-tz UTC+5 --drift-ahead 3m \
    --tz-tag +05:00 --copy-matched --verbose

  # B) You know the exact correction (+1:57:00) and want to be explicit
  geotag-final.sh --photos /p --pool /gpx \
    --shift +1:57:0 --tz-tag +05:00 --verbose

  # C) Only geotag; timestamps are already correct and have +05:00 tags
  geotag-final.sh --photos /p --pool /gpx --to-tz UTC+5 --verbose
H
}

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --photos) PHOTOS_ROOT="${2:-}"; shift 2;;
    --pool) GPX_POOL="${2:-}"; shift 2;;

    --from-tz) FROM_TZ="${2:-}"; shift 2;;
    --to-tz) TO_TZ="${2:-}"; shift 2;;

    --drift-ahead)  DRIFT_KIND="ahead";  DRIFT_VAL="${2:-}"; shift 2;;
    --drift-behind) DRIFT_KIND="behind"; DRIFT_VAL="${2:-}"; shift 2;;
    --drift-exact)  DRIFT_KIND="exact";  DRIFT_VAL="${2:-}"; shift 2;;

    --shift) SHIFT_EXPLICIT="${2:-}"; shift 2;;
    --tz-tag) TZ_TAG="${2:-}"; shift 2;;
    --set-offset) TZ_TAG="${2:-}"; shift 2;;   # backwards-compat alias

    --copy-matched) COPY_MATCHED=1; shift;;
    --no-overwrite) OVERWRITE=0; shift;;
    --max-ext) MAX_EXT_SECS="${2:-0}"; shift 2;;
    --verbose) VERBOSE=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

PHOTOS_ROOT="${PHOTOS_ROOT%/}"
[[ -d "$PHOTOS_ROOT" ]] || die "--photos '$PHOTOS_ROOT' not found"
if [[ -n "$GPX_POOL" ]]; then GPX_POOL="${GPX_POOL%/}"; [[ -d "$GPX_POOL" ]] || die "--pool '$GPX_POOL' not found"; fi

# ---------- helpers ----------
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

parse_tz_to_seconds(){
  local z; z="$(trim "$1")"
  if [[ "$z" == "Z" || "$z" == "UTC" || "$z" == "utc" ]]; then echo 0; return; fi
  if [[ "$z" =~ ^UTC([+-].+)$ ]]; then z="${BASH_REMATCH[1]}"; fi
  if [[ "$z" =~ ^([+-])([0-9]{1,2})(?::([0-9]{2}))?$ ]]; then
    local sgn="${BASH_REMATCH[1]}" hh="${BASH_REMATCH[2]}" mm="${BASH_REMATCH[3]:-00}"
    ((10#$hh<=14)) || die "TZ hour $z"; ((10#$mm<=59)) || die "TZ min $z"
    local secs=$((10#$hh*3600 + 10#$mm*60)); [[ $sgn == "-" ]] && secs=$((-secs)); echo "$secs"; return
  fi
  TZ="$z" date +%z >/dev/null 2>&1 || die "Unknown TZ: $z"
  local s; s="$(TZ="$z" date +%z)"; local sgn="${s:0:1}" hh="${s:1:2}" mm="${s:3:2}"
  local secs=$((10#$hh*3600 + 10#$mm*60)); [[ $sgn == "-" ]] && secs=$((-secs)); echo "$secs"
}

secs_to_hms_np(){ # non-padded H:M:S (ExifTool accepts)
  local s=$1; local sign=""; [[ $s -lt 0 ]] && sign="-"
  [[ $s -lt 0 ]] && s=$((-s))
  printf "%s%d:%d:%d" "$sign" $((s/3600)) $(((s%3600)/60)) $((s%60))
}
hms_abs(){ local s=$1; [[ $s -lt 0 ]] && s=$((-s)); printf "%d:%d:%d" $((s/3600)) $(((s%3600)/60)) $((s%60)); }

parse_drift_abs(){
  local v="$1"
  if   [[ "$v" =~ ^([0-9]+):([0-9]{1,2})m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  elif [[ "$v" =~ ^([+-]?)([0-9]+)s$ ]]; then echo $(( ${BASH_REMATCH[2]} ))
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then echo "$v"
  else die "Bad drift '$v' (use 3m, 45s, 1:30m, +75s)"; fi
}
parse_drift_exact(){ local v="$1" sign="+"; if [[ "$v" =~ ^([+-])(.*)$ ]]; then sign="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; fi; local a; a="$(parse_drift_abs "$v")"; [[ $sign == "-" ]] && echo $((-a)) || echo "$a"; }

# argfile runner: writes all options and files to a temp file and runs exiftool -@
xt_run(){
  local tmp; tmp="$(mktemp)"
  # global flags first
  echo "-P" >>"$tmp"
  [[ $OVERWRITE -eq 1 ]] && echo "-overwrite_original" >>"$tmp"
  [[ $MAX_EXT_SECS -gt 0 ]] && echo "-api GeoMaxExtSecs=$MAX_EXT_SECS" >>"$tmp"
  # rest of opts
  while [[ $# -gt 0 && "$1" != "--" ]]; do printf '%s\n' "$1" >>"$tmp"; shift; done
  [[ "${1:-}" == "--" ]] && shift
  # files
  while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >>"$tmp"; shift; done
  if [[ $VERBOSE -eq 1 ]]; then echo "[ARGFILE]"; sed 's/^/  /' "$tmp"; fi
  [[ $DRYRUN -eq 1 ]] || exiftool -@ "$tmp"
  rm -f "$tmp"
}

# ---------- compute shift & geodrift ----------
# explicit shift?
SHIFT_SECS=0; SHIFT_AUTO=0
if [[ -n "$SHIFT_EXPLICIT" ]]; then
  [[ "$SHIFT_EXPLICIT" =~ ^[+-][0-9]+:[0-9]+:[0-9]+$ ]] || die "--shift must be ±H:M:S"
  # don't convert here; we will pass string as-is
else
  # compute from FROM/TO and drift
  if [[ -n "$FROM_TZ" && -n "$TO_TZ" ]]; then
    local from_s to_s drift_s=0
    from_s=$(parse_tz_to_seconds "$FROM_TZ")
    to_s=$(parse_tz_to_seconds "$TO_TZ")
    case "$DRIFT_KIND" in
      ahead)  drift_s=$(parse_drift_abs "$DRIFT_VAL");;    # ahead -> subtract from net later
      behind) drift_s=$(( - $(parse_drift_abs "$DRIFT_VAL") ));; # behind -> add to net later (note sign)
      exact)  drift_s=$(parse_drift_exact "$DRIFT_VAL");;
      "" ) drift_s=0;;
      * ) die "drift kind must be ahead|behind|exact";;
    esac
    # net = (to − from) − ahead + behind  == (to − from) + drift_s  (with our sign for behind negative)
    # careful: for ahead we set drift_s positive above, so we SUBTRACT it:
    NET=$(( to_s - from_s - (drift_s>0?drift_s:0) + (drift_s<0?(-drift_s):0) ))
    # The above is messy; clearer:
    # We'll recompute properly:
    SHIFT_SECS=$(( to_s - from_s ))
    if [[ "$DRIFT_KIND" == "ahead" ]]; then
      SHIFT_SECS=$(( SHIFT_SECS - $(parse_drift_abs "$DRIFT_VAL") ))
    elif [[ "$DRIFT_KIND" == "behind" ]]; then
      SHIFT_SECS=$(( SHIFT_SECS + $(parse_drift_abs "$DRIFT_VAL") ))
    elif [[ "$DRIFT_KIND" == "exact" ]]; then
      SHIFT_SECS=$(( SHIFT_SECS + $(parse_drift_exact "$DRIFT_VAL") ))
    fi
    SHIFT_AUTO=1
  fi
fi

# geodrift to apply during geotag:
GEODRIFT=""
if [[ -n "$SHIFT_EXPLICIT" || $SHIFT_AUTO -eq 1 ]]; then
  # drift already absorbed into timestamps; no geodrift
  GEODRIFT=""
else
  # not normalizing times: apply only drift during geotag
  if [[ "$DRIFT_KIND" == "ahead" ]]; then GEODRIFT="+$(hms_abs "$(parse_drift_abs "$DRIFT_VAL")")"
  elif [[ "$DRIFT_KIND" == "behind" ]]; then GEODRIFT="-$(hms_abs "$(parse_drift_abs "$DRIFT_VAL")")"
  elif [[ "$DRIFT_KIND" == "exact" ]]; then
    local d; d=$(parse_drift_exact "$DRIFT_VAL"); [[ $d -ge 0 ]] && GEODRIFT="+$(hms_abs "$d")" || GEODRIFT="-$(hms_abs "$d")"
  fi
fi

# preferred TZ for geotag:
GEOTAG_TZ=""
if [[ -n "$TO_TZ" ]]; then
  # normalize to ±HH:MM string
  to_s=$(parse_tz_to_seconds "$TO_TZ")
  local sign="+"; [[ $to_s -lt 0 ]] && sign="-" && to_s=$((-to_s))
  GEOTAG_TZ=$(printf "%s%02d:%02d" "$sign" $((to_s/3600)) $(((to_s%3600)/60)))
elif [[ -n "$TZ_TAG" ]]; then
  GEOTAG_TZ="$TZ_TAG"
fi

# ---------- Phase 1: time rewrite & tz tags (if requested) ----------
if [[ -n "$SHIFT_EXPLICIT" || $SHIFT_AUTO -eq 1 || -n "$TZ_TAG" ]]; then
  while IFS= read -r -d '' dir; do
    while IFS= read -r -d '' f; do
      # Apply shift if requested
      if [[ -n "$SHIFT_EXPLICIT" ]]; then
        if [[ "${SHIFT_EXPLICIT:0:1}" == "+" ]]; then
          xt_run "-DateTimeOriginal+=${SHIFT_EXPLICIT:1}" "-CreateDate+=${SHIFT_EXPLICIT:1}" "-ModifyDate+=${SHIFT_EXPLICIT:1}" -- "$f"
        else
          xt_run "-DateTimeOriginal-=${SHIFT_EXPLICIT:1}" "-CreateDate-=${SHIFT_EXPLICIT:1}" "-ModifyDate-=${SHIFT_EXPLICIT:1}" -- "$f"
        fi
      elif [[ $SHIFT_AUTO -eq 1 && $SHIFT_SECS -ne 0 ]]; then
        abs=$(hms_abs "$SHIFT_SECS")
        if [[ $SHIFT_SECS -gt 0 ]]; then
          xt_run "-DateTimeOriginal+=${abs}" "-CreateDate+=${abs}" "-ModifyDate+=${abs}" -- "$f"
        else
          xt_run "-DateTimeOriginal-=${abs}" "-CreateDate-=${abs}" "-ModifyDate-=${abs}" -- "$f"
        fi
      fi

      # Write TZ tags if requested
      if [[ -n "$TZ_TAG" || -n "$TO_TZ" ]]; then
        tztowrite="$TZ_TAG"
        if [[ -z "$tztowrite" && -n "$TO_TZ" ]]; then
          # derive from TO_TZ
          to_s2=$(parse_tz_to_seconds "$TO_TZ"); local sgn="+"; [[ $to_s2 -lt 0 ]] && sgn="-" && to_s2=$((-to_s2))
          tztowrite=$(printf "%s%02d:%02d" "$sgn" $((to_s2/3600)) $(((to_s2%3600)/60)))
        fi
        [[ "$tztowrite" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "--tz-tag must be ±HH:MM"
        xt_run "-OffsetTimeOriginal=$tztowrite" "-OffsetTime=$tztowrite" "-OffsetTimeDigitized=$tztowrite" -- "$f"
      fi
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0)
  done < <(find "$PHOTOS_ROOT" -type d -print0)
fi

# ---------- Phase 2: geotag ----------
echo "Geotagging..."
while IFS= read -r -d '' dir; do
  shopt -s nullglob
  local_gpx=( "$dir"/*.gpx "$dir"/*.GPX )
  pool_gpx=( ); [[ -n "$GPX_POOL" ]] && pool_gpx=( "$GPX_POOL"/*.gpx "$GPX_POOL"/*.GPX )
  shopt -u nullglob

  while IFS= read -r -d '' f; do
    # determine TZ to use for this file at match time
    tz_for_file="$GEOTAG_TZ"
    if [[ -z "$tz_for_file" ]]; then
      # try OffsetTimeOriginal in the file
      tz_for_file="$(exiftool -q -q -n -S -OffsetTimeOriginal "$f" | awk '/OffsetTimeOriginal/ {print $2}')"
      if [[ -z "$tz_for_file" ]]; then
        echo "[SKIP] $(basename "$f"): no --to-tz/--tz-tag and no OffsetTimeOriginal; not guessing" >&2
        continue
      fi
    fi
    [[ "$tz_for_file" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || die "Bad TZ '$tz_for_file' (need ±HH:MM)"

    geotime_line="-geotime<\${DateTimeOriginal}${tz_for_file}>"
    geo_sync_line=""
    if [[ -n "$GEODRIFT" ]]; then geo_sync_line="-geosync=${GEODRIFT}"; fi

    # try local GPX dir first
    changed=0
    if (( ${#local_gpx[@]} )); then
      xt_run "$geotime_line" ${geo_sync_line:+$geo_sync_line} -geotag "$dir" -- "$f" || true
      # check if now tagged
      if exiftool -q -q -n -GPSLatitude "$f" | grep -q 'GPSLatitude'; then changed=1; fi
    fi

    # fallback to pool GPX one by one
    if (( changed==0 && ${#pool_gpx[@]} )); then
      before=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$f" | wc -l | tr -d ' ')
      for g in "${pool_gpx[@]}"; do
        xt_run "$geotime_line" ${geo_sync_line:+$geo_sync_line} -geotag "$g" -- "$f" || true
        after=$(exiftool -q -q -if 'not $gpslatitude' -T -filename "$f" | wc -l | tr -d ' ')
        if (( before>0 && after==0 )); then
          changed=1
          if (( COPY_MATCHED==1 && DRYRUN==0 )); then
            dst="$dir/$(basename "$g")"
            if [[ -e "$dst" ]]; then n=1; while [[ -e "${dst%.*}_$n.${dst##*.}" ]]; do n=$((n+1)); done; dst="${dst%.*}_$n.${dst##*.}"; fi
            cp -n "$g" "$dst" || true
          fi
          break
        fi
      done
    fi

    if (( VERBOSE==1 )); then
      if (( changed==1 )); then
        exiftool -q -q -n -S -GPSLatitude -GPSLongitude "$f" | sed 's/^/[GPS] /'
      else
        echo "[NO MATCH] $(basename "$f")"
      fi
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.dng' -o -iname '*.nef' -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.tif' -o -iname '*.tiff' \) -print0)
done < <(find "$PHOTOS_ROOT" -type d -print0)

echo "Done."
