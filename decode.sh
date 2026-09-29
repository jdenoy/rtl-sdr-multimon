#!/usr/bin/env bash
# Tune an RTL-SDR dongle with rtl_fm and decode the audio with multimon-ng.
# Run ./decode.sh -h for usage.
set -uo pipefail

# Demodulators that are not signal decoders (graphical scopes, raw sample dump).
NON_DECODERS="SCOPE SDL_SCOPE DUMPCSV"

FREQ=""
DECODERS="zvei"
GAIN=""
PPM="0"
SQUELCH="0"
DEVICE="0"
MODULATION="fm"
LOGFILE=""
INPUT=""
EXTRA=()

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v multimon-ng >/dev/null || die "multimon-ng not found, run ./setup.sh first"

# Ask multimon-ng itself which demodulators this build supports.
AVAILABLE="$(multimon-ng -h 2>&1 | sed -n 's/^Available demodulators: //p')"
[ -n "$AVAILABLE" ] || die "could not read the demodulator list from multimon-ng -h"

DECODABLE=""
for d in $AVAILABLE; do
  case " $NON_DECODERS " in *" $d "*) ;; *) DECODABLE="$DECODABLE $d" ;; esac
done
DECODABLE="${DECODABLE# }"

usage() {
  cat <<EOF
Usage: $(basename "$0") -f FREQ [options] [-- extra multimon-ng args]

  -f FREQ     Frequency, e.g. 446.00625M, 169.650M, 152512500   (required unless -i)
  -d LIST     Comma-separated decoders or groups, case-insensitive (default: zvei)
  -g GAIN     Tuner gain in dB (default: automatic)
  -p PPM      Frequency correction in ppm (default: 0)
  -l LEVEL    Squelch level, 0 = off (default: 0)
  -D INDEX    RTL-SDR device index (default: 0)
  -M MOD      Demodulation for rtl_fm: fm, am, usb, lsb (default: fm)
  -o FILE     Also append decoded lines to FILE
  -i FILE     Decode an audio file instead of the dongle (wav/flac/..., or raw 22050 Hz s16le)
  -L          List decoders and groups, then exit
  -h          This help

Groups:
  zvei      ZVEI1 ZVEI2 ZVEI3 DZVEI PZVEI
  selcall   zvei + EEA EIA CCIR
  pocsag    POCSAG512 POCSAG1200 POCSAG2400
  flex      FLEX FLEX_NEXT
  afsk      AFSK1200 AFSK2400 AFSK2400_2 AFSK2400_3
  all       every decoder: $DECODABLE

Examples:
  $(basename "$0") -f 446.00625M                         # ZVEI (all variants)
  $(basename "$0") -f 169.650M -d pocsag -g 40 -p 52
  $(basename "$0") -f 144.800M -d afsk1200 -- -A           # APRS in TNC2 format
  $(basename "$0") -f 160.500M -d selcall,dtmf -o log.txt
EOF
}

expand_group() {
  case "$1" in
    ZVEI)    echo "ZVEI1 ZVEI2 ZVEI3 DZVEI PZVEI" ;;
    SELCALL) echo "ZVEI1 ZVEI2 ZVEI3 DZVEI PZVEI EEA EIA CCIR" ;;
    POCSAG)  echo "POCSAG512 POCSAG1200 POCSAG2400" ;;
    FLEX)    echo "FLEX FLEX_NEXT" ;;
    AFSK)    echo "AFSK1200 AFSK2400 AFSK2400_2 AFSK2400_3" ;;
    ALL)     echo "$DECODABLE" ;;
    *)       echo "$1" ;;
  esac
}

while getopts ":f:d:g:p:l:D:M:o:i:Lh" opt; do
  case "$opt" in
    f) FREQ="$OPTARG" ;;
    d) DECODERS="$OPTARG" ;;
    g) GAIN="$OPTARG" ;;
    p) PPM="$OPTARG" ;;
    l) SQUELCH="$OPTARG" ;;
    D) DEVICE="$OPTARG" ;;
    M) MODULATION="$OPTARG" ;;
    o) LOGFILE="$OPTARG" ;;
    i) INPUT="$OPTARG" ;;
    L) echo "Decoders: $DECODABLE"; echo "Groups:   zvei selcall pocsag flex afsk all"; exit 0 ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG needs a value" ;;
    *) die "unknown option -$OPTARG (see -h)" ;;
  esac
done
shift $((OPTIND - 1))
[ "${1:-}" = "--" ] && shift
EXTRA=("$@")

[ -n "$FREQ" ] || [ -n "$INPUT" ] || { usage; die "-f FREQ is required"; }

# Resolve decoder list: uppercase, expand groups, validate, de-duplicate.
SELECTED=""
for item in $(printf '%s' "$DECODERS" | tr ',' ' ' | tr '[:lower:]' '[:upper:]'); do
  for d in $(expand_group "$item"); do
    case " $AVAILABLE " in
      *" $d "*) ;;
      *) die "unknown decoder '$d'. Available: $DECODABLE" ;;
    esac
    case " $SELECTED " in *" $d "*) ;; *) SELECTED="$SELECTED $d" ;; esac
  done
done
SELECTED="${SELECTED# }"

output() {
  if [ -n "$LOGFILE" ]; then tee -a "$LOGFILE"; else cat; fi
}

# Raw mono s16le 22050 Hz audio on stdout: what every multimon-ng demodulator expects.
audio_source() {
  if [ -n "$INPUT" ]; then
    case "$INPUT" in
      *.raw) cat "$INPUT" ;;
      *) sox -q "$INPUT" -t raw -r 22050 -e signed-integer -b 16 -c 1 - ;;
    esac
  else
    rtl_fm "${RTL_ARGS[@]}" -
  fi
}

# One multimon-ng per decoder: the selcall decoders print digit by digit, so
# several decoders in one process interleave their output on the same line.
decode() {
  local fifos=() d
  for d in $SELECTED; do
    mkfifo "$FIFO_DIR/$d"
    fifos+=("$FIFO_DIR/$d")
    multimon-ng --timestamp -c -a "$d" ${EXTRA[@]+"${EXTRA[@]}"} -t raw "$FIFO_DIR/$d" 2>&1 \
      | awk -v tag="$d" '/^(multimon-ng [0-9]|  \(C\)|Available demodulators:|Enabled demodulators:)/ {next}
             !NF {next}
             index($0, tag ":") == 0 { sub(/^[0-9-]+ [0-9:]+: /, "&" tag ": ") }
             {print; fflush()}' &
  done
  audio_source | tee "${fifos[@]}" >/dev/null
  wait
}

echo "Decoders: $SELECTED" >&2
[ -n "$LOGFILE" ] && echo "Logging:  $LOGFILE" >&2

if [ -n "$INPUT" ]; then
  [ -f "$INPUT" ] || die "no such file: $INPUT"
  case "$INPUT" in *.raw) ;; *) command -v sox >/dev/null || die "sox is needed to read $INPUT, run ./setup.sh" ;; esac
  echo "Input:    $INPUT" >&2
else
  command -v rtl_fm >/dev/null || die "rtl_fm not found, run ./setup.sh first"
  RTL_ARGS=(-d "$DEVICE" -M "$MODULATION" -f "$FREQ" -s 22050 -p "$PPM" -l "$SQUELCH")
  [ -n "$GAIN" ] && RTL_ARGS+=(-g "$GAIN")
  echo "Tuning:   $FREQ (mod=$MODULATION gain=${GAIN:-auto} ppm=$PPM squelch=$SQUELCH device=$DEVICE)" >&2
  echo "Ctrl-C to stop." >&2
fi

FIFO_DIR="$(mktemp -d)"
trap 'rm -rf "$FIFO_DIR"' EXIT

# Run the pipeline as its own job (process group) so Ctrl-C or kill on this
# script stops rtl_fm and every multimon-ng, not just the script itself.
set -m
decode | output &
PGID="$(jobs -p %1)"
trap 'trap - INT TERM; kill -TERM -- "-$PGID" 2>/dev/null; wait; exit 130' INT TERM
wait "$!"
