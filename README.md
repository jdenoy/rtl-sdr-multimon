# rtl-sdr-multimon

Two shell scripts to decode radio signals with an RTL-SDR dongle and [multimon-ng](https://github.com/EliasOenal/multimon-ng): ZVEI selcall IDs by default, and any other mode multimon-ng supports (POCSAG, FLEX, DTMF, AFSK/APRS, EAS, CCIR, EEA, Morse, ...).

- `setup.sh` installs the RTL-SDR tools and builds multimon-ng.
- `decode.sh` tunes the dongle to a frequency and runs the decoders you choose.

## Requirements

- An RTL-SDR dongle (RTL2832U based, e.g. R820T/R828D tuner)
- macOS with [Homebrew](https://brew.sh), or a Debian/Ubuntu/Raspberry Pi OS system with `apt`

## Setup

```sh
./setup.sh
```

This installs `librtlsdr` (`rtl_fm`, `rtl_test`), `cmake`, `git` and `sox`, then clones and builds multimon-ng from source into `.build/` and installs it to `/usr/local/bin` (multimon-ng is not packaged in Homebrew). It finishes by checking that a dongle is detected.

On Linux it also blacklists the `dvb_usb_rtl28xxu` kernel driver, which otherwise claims the dongle. Unplug and replug the dongle afterwards.

Options (environment variables):

| Variable    | Default       | Purpose                                   |
|-------------|---------------|-------------------------------------------|
| `FORCE=1`   | off           | Rebuild multimon-ng even if installed     |
| `PREFIX`    | `/usr/local`  | Install prefix for multimon-ng            |
| `BUILD_DIR` | `./.build`    | Where multimon-ng is cloned and built     |

## Usage

```sh
./decode.sh -f FREQ [options] [-- extra multimon-ng args]
```

| Option     | Meaning                                                          | Default   |
|------------|------------------------------------------------------------------|-----------|
| `-f FREQ`  | Frequency, e.g. `446.00625M`, `169.650M`, `152512500`            | required  |
| `-d LIST`  | Comma-separated decoders or groups, case-insensitive             | `zvei`    |
| `-g GAIN`  | Tuner gain in dB                                                 | automatic |
| `-p PPM`   | Frequency correction in ppm                                      | `0`       |
| `-l LEVEL` | Squelch level, `0` = off                                         | `0`       |
| `-D INDEX` | RTL-SDR device index                                             | `0`       |
| `-M MOD`   | rtl_fm demodulation: `fm`, `am`, `usb`, `lsb`                    | `fm`      |
| `-o FILE`  | Also append decoded lines to FILE                                |           |
| `-i FILE`  | Decode an audio file instead of the dongle (wav/flac/..., or raw 22050 Hz s16le) | |
| `-L`       | List decoders and groups, then exit                              |           |
| `-h`       | Help                                                             |           |

Anything after `--` is passed to every multimon-ng instance (for example `-A` for APRS output, or `-e` to hide empty POCSAG messages).

### Examples

```sh
./decode.sh -f 446.00625M                         # all ZVEI variants
./decode.sh -f 160.500M -d zvei1 -o calls.log     # only ZVEI1, logged to a file
./decode.sh -f 160.500M -d selcall,dtmf           # every selcall format + DTMF
./decode.sh -f 169.650M -d pocsag -g 40 -p 52     # POCSAG with fixed gain and ppm
./decode.sh -f 144.800M -d afsk1200 -- -A         # APRS in TNC2 format
./decode.sh -i recording.wav -d all               # decode a recording
```

Output is one timestamped line per decode, prefixed with the decoder name:

```
2026-09-29 09:55:46: ZVEI1: 12345
2026-09-29 09:55:46: PZVEI: 12345
```

## Decoders

The list is read from `multimon-ng -h` at runtime, so it always matches the installed build. With multimon-ng 1.6.2:

`POCSAG512 POCSAG1200 POCSAG2400 FLEX FLEX_NEXT GSC EAS UFSK1200 CLIPFSK FMSFSK AFSK1200 AFSK2400 AFSK2400_2 AFSK2400_3 HAPN4800 FSK9600 DTMF ZVEI1 ZVEI2 ZVEI3 DZVEI PZVEI EEA EIA CCIR MORSE_CW X10`

`SCOPE`, `SDL_SCOPE` and `DUMPCSV` are excluded: they are display or debug tools, not decoders.

Groups:

| Group     | Expands to                                   |
|-----------|----------------------------------------------|
| `zvei`    | `ZVEI1 ZVEI2 ZVEI3 DZVEI PZVEI`              |
| `selcall` | `zvei` + `EEA EIA CCIR`                      |
| `pocsag`  | `POCSAG512 POCSAG1200 POCSAG2400`            |
| `flex`    | `FLEX FLEX_NEXT`                             |
| `afsk`    | `AFSK1200 AFSK2400 AFSK2400_2 AFSK2400_3`    |
| `all`     | every decoder above                          |

## How it works

`rtl_fm` demodulates the signal and outputs raw mono 16-bit audio at 22050 Hz, the format multimon-ng expects. The audio is split with `tee` into one named pipe per decoder, and each decoder runs in its own multimon-ng process.

One process per decoder is deliberate: the selcall decoders (ZVEI, CCIR, EEA, EIA) print digits one at a time, so several decoders in a single multimon-ng process interleave their output on the same line. Separate processes keep every decode on its own labelled line.

Ctrl-C (or `kill`) stops `rtl_fm` and every multimon-ng instance.

## Tips

- **Several ZVEI lines for one call.** The ZVEI variants share most of their tones, so one transmission is often reported by several of them. Once you know which variant is used locally, run only that one (e.g. `-d zvei1`).
- **Noise with `-d all`.** Some FSK decoders (notably `UFSK1200`) print random bytes on noise. Select only the modes you need.
- **Frequency error.** Cheap dongles are often off by tens of ppm. If tones decode poorly, measure the error (e.g. with `kal` or `rtl_test -p`) and pass it with `-p`.
- **Gain.** Automatic gain works for strong signals; for weak or crowded bands try a fixed value such as `-g 30` to `-g 45`.
- **Testing without RF.** Record audio or generate tones with `sox` and use `-i`. For example, ZVEI1 `12345` (70 ms tones):

  ```sh
  for f in 1060 1160 1270 1400 1530; do sox -n -r 22050 -c 1 -b 16 t$f.wav synth 0.07 sine $f vol 0.5; done
  sox t1060.wav t1160.wav t1270.wav t1400.wav t1530.wav zvei.wav
  ./decode.sh -i zvei.wav -d zvei1
  ```

## Legal

Receiving and decoding radio traffic is regulated differently in each country. In many places, including France, listening to non-public services (pagers, emergency services) is restricted, and disclosing or using the content is prohibited. Check your local rules before you listen.
