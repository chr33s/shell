#!/usr/bin/env python3
import argparse
from pathlib import Path

files = [
    "arabic.c", "autocmd.c", "blowfish.c", "buffer.c", "change.c", "channel.c",
    "charset.c", "cindent.c", "cmdexpand.c", "cmdhist.c", "crypt.c", "crypt_zip.c",
    "debugger.c", "dict.c", "diff.c", "digraph.c", "drawline.c", "drawscreen.c",
    "edit.c", "eval.c", "evalfunc.c", "evalvars.c", "ex_cmds.c", "ex_cmds2.c",
    "ex_docmd.c", "ex_eval.c", "ex_getln.c", "fileio.c", "filepath.c", "findfile.c",
    "fold.c", "getchar.c", "hardcopy.c", "highlight.c", "indent.c", "insexpand.c",
    "list.c", "main.c", "map.c", "mark.c", "mbyte.c", "memfile.c", "memline.c",
    "menu.c", "message.c", "misc1.c", "misc2.c", "mouse.c", "normal.c", "ops.c",
    "option.c", "optionstr.c", "os_unix.c", "popupmenu.c", "popupwin.c", "profiler.c",
    "quickfix.c", "regexp.c", "regexp_nfa.c", "register.c", "screen.c", "scriptfile.c",
    "search.c", "sign.c", "spell.c", "spellfile.c", "spellsuggest.c", "syntax.c",
    "tag.c", "term.c", "textprop.c", "ui.c", "undo.c", "usercmd.c", "userfunc.c",
    "viminfo.c", "window.c"
]

def count_tls(filepath: Path):
    try:
        return filepath.read_text(encoding="utf-8").count("static __thread")
    except OSError:
        return 0

def main():
    default_new_src = Path(__file__).resolve().parent / "src"
    parser = argparse.ArgumentParser(
        description="Compare static __thread usage between two Vim source trees."
    )
    parser.add_argument(
        "--old-src",
        type=Path,
        required=True,
        help="Source directory from the baseline Vim checkout",
    )
    parser.add_argument(
        "--new-src",
        type=Path,
        default=default_new_src,
        help=f"Source directory to inspect (default: {default_new_src})",
    )
    args = parser.parse_args()

    old_dir = args.old_src.expanduser().resolve()
    new_dir = args.new_src.expanduser().resolve()
    for label, directory in (("old", old_dir), ("new", new_dir)):
        if not directory.is_dir():
            parser.error(f"{label} source directory not found: {directory}")

    results = []
    for filename in files:
        old_count = count_tls(old_dir / filename)
        new_count = count_tls(new_dir / filename)
        if old_count > new_count:
            results.append((filename, old_count, new_count, old_count - new_count))

    results.sort(key=lambda result: result[3], reverse=True)
    print("=== Files needing TLS additions (sorted by missing count) ===")
    for filename, old, new, missing in results:
        print(f"{filename}: old={old} new={new} missing={missing}")

    print(f"\nTotal files needing work: {len(results)}")
    print(f"Total missing TLS markers: {sum(result[3] for result in results)}")


if __name__ == "__main__":
    main()
