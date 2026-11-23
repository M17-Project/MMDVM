#!/bin/bash
#
# Builds the firmware for every board in boards.json and writes a release
# manifest (firmware.json) and SHA256SUMS beside the images. The manifest's
# format is 1; a change readers must understand bumps it.
#
#   scripts/release_build.sh <output dir> [release tag]
#
# A release tag is the firmware's version from Version.h (G4KLX's), with a
# v and -m17: v<VERSION>-m17 (v20260424-m17) for a release, and
# v<VERSION>-m17.<n> (v20260424-m17.2) for a later M17 release of the same
# upstream version. Either followed by .<label>.<n> (v20260424-m17.test.1,
# v20260424-m17.2.beta.1) is a pre-release. Pi-Star only reads tags with
# one hyphen (v<8 digits>-<letters, digits and dots>), so the label is
# joined with dots. A tag that does not match Version.h fails the build.
# Without a tag the build is named v<VERSION>-m17.g<commit> (CI builds and
# local tests).
#
# Each distinct build (Makefile target, MCU crystal, Config.h options) is
# made once, from the committed tree (HEAD) in a scratch clone, so the
# working tree's Config.h is never touched and uncommitted edits are not
# built. Config.h is upstream's, with only a board's define / undefine
# applied.
#
# Fails when a Makefile board target is not used by any board, or a board
# names a target that does not exist.
#
# Needs: arm-none-eabi-gcc, make, git, jq, sha256sum, strings, and the
# STM32F4XX_Lib and STM32F7XX_Lib submodules (git submodule update --init).

set -euo pipefail

OUT=$(realpath -m "${1:?usage: $0 <output dir> [release tag]}")
SRC=$(cd "$(dirname "$0")/.." && pwd)
TAG=${2:-}
COMMIT=$(git -C "$SRC" rev-parse HEAD)
SHORT=$(git -C "$SRC" rev-parse --short HEAD)
MAP=$(git -C "$SRC" show "$COMMIT:boards.json")
MAKEFILE=$(git -C "$SRC" show "$COMMIT:Makefile")

# The firmware version, as Version.h has it
DATE=$(git -C "$SRC" show "$COMMIT:Version.h" | sed -nE 's/^#define[[:space:]]+VERSION[[:space:]]+"([0-9]{8})".*/\1/p')
if [[ ! $DATE =~ ^[0-9]{8}$ ]]; then
	echo "Version.h: cannot read the version (got '$DATE')" >&2
	exit 1
fi
VERSION="v$DATE"
PRERELEASE=true
if [ -n "$TAG" ]; then
	if [[ ! $TAG =~ ^$VERSION-m17(\.[0-9]+)?(\.[A-Za-z][A-Za-z0-9]*\.[0-9]+)?$ ]]; then
		echo "Tag $TAG does not match the firmware version $VERSION (Version.h): use $VERSION-m17[.<n>] for a release or $VERSION-m17[.<n>].<label>.<n> for a pre-release" >&2
		exit 1
	fi
	[ -z "${BASH_REMATCH[2]}" ] && PRERELEASE=false
	RELEASE=$TAG
else
	RELEASE="$VERSION-m17.g$SHORT"
fi

for lib in STM32F4XX_Lib STM32F7XX_Lib; do
	if [ ! -d "$SRC/$lib/CMSIS" ] && [ ! -d "$SRC/$lib/Device" ] && [ -z "$(ls -A "$SRC/$lib" 2>/dev/null)" ]; then
		echo "$lib is missing: git submodule update --init" >&2
		exit 1
	fi
done

# The Makefile's board targets: those that build a release image
targets=$(sed -nE 's/^([a-z0-9_-]+): release_f[47]$/\1/p' <<<"$MAKEFILE" | sort -u)
# A target's MCU: the -DSTM32F... part of the DEFS_ it uses
mcu() {
	local defs
	defs=$(sed -nE "s/^$1: CFLAGS\+=.*\\\$\((DEFS_[A-Z0-9_]+)\).*/\1/p" <<<"$MAKEFILE" | head -1)
	sed -nE "s/^$defs=.*-D(STM32F[0-9]+[A-Za-z0-9_]*xx).*/\1/p" <<<"$MAKEFILE" | head -1
}
# The map: unique ids and aliases, targets that exist, every target used
dupes=$(jq -r '[.boards[] | .id, (.aliases // [])[]] | group_by(.) | map(select(length > 1) | .[0]) | .[]' <<<"$MAP")
if [ -n "$dupes" ]; then
	echo "boards.json: names used twice: $dupes" >&2
	exit 1
fi
mapped=$(jq -r '.boards[].target' <<<"$MAP" | sort -u)
missing=$(comm -13 <(echo "$targets") <(echo "$mapped"))
unmapped=$(comm -23 <(echo "$targets") <(echo "$mapped"))
if [ -n "$missing" ] || [ -n "$unmapped" ]; then
	[ -n "$missing" ] && echo "boards.json: no such Makefile target: $missing" >&2
	[ -n "$unmapped" ] && echo "boards.json: Makefile targets no board uses: $unmapped" >&2
	exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/images"
# shellcheck disable=SC2016 # $(...) is make's, not the shell's
echo '$(info PISTAR_OSC=$(OSC))' > "$WORK/osc.mk"
rm -f "$OUT"/*.bin "$OUT/firmware.json" "$OUT/SHA256SUMS"

# A board's build: target, crystal and Config.h changes (boards that share
# them share an image)
buildkey() { jq -r '[.target, (.hse // "" | tostring), ((.define // []) | sort | join("+")), ((.undefine // []) | sort | join("+"))] | join(":")' <<<"$1"; }

declare -A built=() crystal=()
builds=0
while read -r entry; do
	key=$(buildkey "$entry")
	[ -n "${built[$key]:-}" ] && continue
	n=$((builds++))
	built[$key]=$n
	target=$(jq -r .target <<<"$entry")
	hse=$(jq -r '.hse // empty' <<<"$entry")
	tree="$WORK/tree"
	git clone --quiet "$SRC" "$tree"
	git -C "$tree" -c advice.detachedHead=false checkout --quiet "$COMMIT"
	cp -a "$SRC/STM32F4XX_Lib/." "$tree/STM32F4XX_Lib/"
	cp -a "$SRC/STM32F7XX_Lib/." "$tree/STM32F7XX_Lib/"
	# Config.h: the board's options cleared, then set
	for name in $(jq -r '(.undefine // [])[]' <<<"$entry"); do
		sed -i -E "s|^([[:space:]]*#define[[:space:]]+$name\b)|// \1|" "$tree/Config.h"
	done
	for name in $(jq -r '(.define // [])[]' <<<"$entry"); do
		sed -i -E "0,/^#endif/s|^#endif|#define $name\n\n#endif|" "$tree/Config.h"
	done
	echo "=== $key"
	# The MCU crystal this build uses, as make expands it for the target
	# (a second makefile, read after the Makefile, prints it)
	crystal[$n]=$(make -C "$tree" -n --no-print-directory -f Makefile -f "$WORK/osc.mk" "$target" ${hse:+OSC=$hse} 2>/dev/null | sed -n 's/^PISTAR_OSC=//p' | head -1)
	make -C "$tree" -j"$(nproc)" "$target" ${hse:+OSC=$hse} >/dev/null
	image=$(ls "$tree"/bin/mmdvm_f[47].bin)
	cp "$image" "$WORK/images/$n.bin"
	rm -rf "$tree"
done < <(jq -c '.boards[]' <<<"$MAP")

# One image per board, with what it reports and how it can be flashed
boards='[]'
while read -r entry; do
	id=$(jq -r .id <<<"$entry")
	target=$(jq -r .target <<<"$entry")
	n=${built[$(buildkey "$entry")]}
	cp "$WORK/images/$n.bin" "$OUT/$id.bin"

	# What the board will answer to GET_VERSION, read from the image itself
	description=$(strings -n 8 "$OUT/$id.bin" | grep -m1 -E '^MMDVM .* GitID #' || true)
	if [ -z "$description" ]; then
		echo "$id: no version string in its image" >&2
		exit 1
	fi
	hse=${crystal[$n]}
	mcu=$(mcu "$target")
	if [[ ! $hse =~ ^[0-9]+$ ]] || [ -z "$mcu" ]; then
		echo "$id: cannot read the MCU or its crystal for target $target from the Makefile" >&2
		exit 1
	fi
	# Each way of flashing it: stm32flash needs both GPIO lines
	if ! jq -e '(.flash // []) | all(.tool == "st-flash" or (.tool == "stm32flash" and .gpio.boot0 != null and .gpio.reset != null))' <<<"$entry" >/dev/null; then
		echo "boards.json: $id: flash entries are st-flash, or stm32flash with gpio boot0 and reset" >&2
		exit 1
	fi

	boards=$(jq --argjson entry "$entry" --arg file "$id.bin" \
		--arg sha "$(sha256sum "$OUT/$id.bin" | cut -d' ' -f1)" \
		--argjson size "$(stat -c %s "$OUT/$id.bin")" \
		--arg description "$description" --arg mcu "$mcu" --argjson hse "$hse" \
		'. + [{id: $entry.id, name: $entry.name, aliases: ($entry.aliases // []),
		       target: $entry.target, mcu: $mcu, hse: $hse,
		       file: $file, size: $size, sha256: $sha,
		       description: $description,
		       hwtype: ($description | capture("^(?<h>MMDVM( [^ ]+)?) [0-9]{8} ").h),
		       tcxo: ($description | capture(" [0-9]{8} (?<t>.*) GitID #").t),
		       flash: [($entry.flash // [])[] | . + {address: "0x08000000"}]}]' <<<"$boards")
done < <(jq -c '.boards[]' <<<"$MAP")

jq -n --arg release "$RELEASE" --arg version "$VERSION" --argjson prerelease "$PRERELEASE" --arg commit "$COMMIT" --arg gitid "$SHORT" \
	--arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson boards "$boards" \
	'{format: 1, family: "MMDVM", release: $release, version: $version, prerelease: $prerelease, commit: $commit, gitid: $gitid, built: $built, boards: $boards}' \
	> "$OUT/firmware.json"

(cd "$OUT" && sha256sum -- *.bin firmware.json > SHA256SUMS)

echo
jq -r '"\(.release) (version \(.version), prerelease \(.prerelease)), GitID \(.gitid)"' "$OUT/firmware.json"
jq -r '.boards[] | "\(.file)\t\(.mcu) \(.hse / 1000000)MHz\t\(.hwtype) / \(.tcxo)\t\([.flash[].tool] | join(",") | if . == "" then "by hand" else . end)\t\(.sha256[0:12])"' "$OUT/firmware.json" | column -t -s $'\t'
