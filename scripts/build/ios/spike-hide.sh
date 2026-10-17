#!/usr/bin/env bash
# anyPC spike (b): can the whole z_generals link be turned into ONE relocatable object whose only
# exported symbol is the entry point, so it can coexist with another engine in one binary?
set -uo pipefail
BUILD="${1:-build/ios-vulkan}"; OUT="$(dirname "$BUILD")/spike-hide"; mkdir -p "$OUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
ENTRY="_SDL_main"   # iOS: SDL_main.h renames main(); in anyPC this becomes generals_main
R="$OUT/report.txt"; : > "$R"
say(){ echo "$*" | tee -a "$R"; }

# 1. recover the exe link inputs from ninja
( cd "$BUILD" && ninja -t commands z_generals | tail -1 ) > "$OUT/link_cmd.txt"
python3 - "$BUILD" "$OUT" <<'PY'
import sys, shlex, os
build, out = sys.argv[1:3]
cmd = open(os.path.join(out, "link_cmd.txt")).read()
toks = shlex.split(cmd)
exp = []
for t in toks:
    if t.startswith("@"):
        exp += shlex.split(open(os.path.join(build, t[1:])).read())
    else:
        exp.append(t)
ins = []
for t in exp:
    if t.endswith((".o", ".a")) and not t.startswith("-"):
        p = t if os.path.isabs(t) else os.path.normpath(os.path.join(build, t))
        if os.path.exists(p): ins.append(p)
open(os.path.join(out, "inputs.txt"), "w").write("\n".join(dict.fromkeys(ins)))
print(len(ins), "inputs")
PY
say "link inputs: $(wc -l < "$OUT/inputs.txt")"

# 2. partial link (archives only contribute members needed from the exe's own objects)
ld -r -arch arm64 -platform_version ios 16.0 16.0 -syslibroot "$SDK" \
   -o "$OUT/raw.o" $(cat "$OUT/inputs.txt") 2> "$OUT/ld_raw.err"
say "ld -r raw exit: $?  size: $(du -h "$OUT/raw.o" 2>/dev/null | cut -f1)"; head -20 "$OUT/ld_raw.err" | tee -a "$R"

# 3a. hide with ld -r + exported list
echo "$ENTRY" > "$OUT/exports.txt"
ld -r -arch arm64 -platform_version ios 16.0 16.0 -syslibroot "$SDK" -exported_symbols_list "$OUT/exports.txt" \
   -o "$OUT/hidden_ldr.o" "$OUT/raw.o" 2> "$OUT/ld_hide.err"
say "hide via ld -r -exported_symbols_list exit: $?"; head -5 "$OUT/ld_hide.err" | tee -a "$R"
# 3b. hide with nmedit (turns every global not in the list into a local symbol)
cp "$OUT/raw.o" "$OUT/hidden_nm.o"; nmedit -s "$OUT/exports.txt" "$OUT/hidden_nm.o" 2> "$OUT/nmedit.err"
say "hide via nmedit exit: $?"; head -5 "$OUT/nmedit.err" | tee -a "$R"

count(){ nm -gUj "$1" 2>/dev/null | wc -l | tr -d ' '; }
say "defined external symbols: raw=$(count "$OUT/raw.o") ld-r=$(count "$OUT/hidden_ldr.o") nmedit=$(count "$OUT/hidden_nm.o")"
for f in raw hidden_ldr hidden_nm; do
  say "--- $f: ObjC classes exported: $(nm -gU "$OUT/$f.o" 2>/dev/null | grep -c ' _OBJC_CLASS_\$_')  weak defs: $(nm -gU "$OUT/$f.o" 2>/dev/null | grep -c ' W ')"
  nm -gU "$OUT/$f.o" 2>/dev/null | head -12 >> "$R"
done
nm -u "$OUT/raw.o" | sed 's/^ *//' | sort -u > "$OUT/undefined.txt"; say "undefined symbols (must come from dylibs): $(wc -l < "$OUT/undefined.txt")"

# 4. coexistence: hidden copy + raw copy of the same engine must link; raw + raw must NOT (control)
for h in hidden_ldr hidden_nm; do
  ld -r -arch arm64 -platform_version ios 16.0 16.0 -syslibroot "$SDK" -o /dev/null "$OUT/$h.o" "$OUT/raw.o" 2> "$OUT/co_$h.err"
  say "coexist [$h + raw engine] exit=$? duplicate-symbol errors: $(grep -c 'duplicate symbol' "$OUT/co_$h.err")"
done
ld -r -arch arm64 -platform_version ios 16.0 16.0 -syslibroot "$SDK" -o /dev/null "$OUT/raw.o" "$OUT/raw.o" 2> "$OUT/co_ctrl.err"
say "control [raw + raw] exit=$? duplicate-symbol errors: $(grep -c 'duplicate symbol' "$OUT/co_ctrl.err")"
