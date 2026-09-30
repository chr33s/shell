#!/usr/bin/env python3
"""
apply_tls.py - Add __thread to static variable declarations for iOS TLS support.

Vim's iOS port needs thread-local storage on static variables so multiple
vim instances can run concurrently.  This script mechanically adds __thread
after 'static' on variable declarations while skipping function declarations,
const data, and entries in the exclusion list.

Usage:
    python3 tools/apply_tls.py --check src/*.c src/*.h   # dry-run report
    python3 tools/apply_tls.py --diff  src/*.c src/*.h   # show unified diff
    python3 tools/apply_tls.py --apply src/*.c src/*.h   # modify files in place
"""

import argparse
import difflib
import os
import re
import sys

# ---------------------------------------------------------------------------
# Heuristics for distinguishing variables from functions
# ---------------------------------------------------------------------------

# Matches a static variable declaration (may span one line).
# Captures: static [qualifiers] type name ...
# We look for 'static' at start of line (possibly indented), not followed by
# __thread, const, inline, INLINE, or DEFINE_.
STATIC_RE = re.compile(
    r'^(\s*)static\s+'        # leading whitespace + 'static'
    r'(?!__thread\b)'         # not already __thread
    r'(?!const\b)'            # not const
    r'(?!inline\b)'           # not inline
    r'(?!INLINE\b)'           # not INLINE
    r'(?!DEFINE_\w)'          # not DEFINE_ macros
)

# A line that looks like a function declaration or definition:
#   static type name(args...
# Key signal: an unquoted '(' appears before any '=' or ';'
FUNC_PAREN_RE = re.compile(
    r'^[\s]*static\s+.*?\b\w+\s*\('  # name followed by (
)

def _has_paren_before_semi_or_eq(line):
    """Return True if '(' appears before '=' or ';' (function signature)."""
    # Strip string literals and comments to avoid false positives
    stripped = re.sub(r'"[^"]*"', '""', line)
    stripped = re.sub(r"'[^']*'", "''", stripped)
    stripped = re.sub(r'/\*.*?\*/', '', stripped)
    stripped = re.sub(r'//.*$', '', stripped)

    pos_paren = stripped.find('(')
    pos_eq = stripped.find('=')
    pos_semi = stripped.find(';')
    pos_bracket = stripped.find('[')

    if pos_paren < 0:
        return False

    # Array declarations have [ before ( sometimes: static int arr[N] = {...};
    if pos_bracket >= 0 and pos_bracket < pos_paren:
        return False

    # If = comes before (, it's an initializer, not a function
    if pos_eq >= 0 and pos_eq < pos_paren:
        return False

    # ( before ; or = -> likely a function
    if pos_semi < 0 and pos_eq < 0:
        return True  # no ; or = at all -> function def continuing on next line
    if pos_semi >= 0 and pos_paren < pos_semi:
        # Check for function pointer variables: static type (*funcptr)(args);
        # The (*name) pattern must appear BEFORE the first '(' to be a funcptr.
        # If the first '(' is directly preceded by an identifier, it's a function.
        rest_after_static = stripped[stripped.index('static') + 6:].strip()
        # Function pointer: the FIRST ( is part of (*name)
        first_paren_context = rest_after_static[:rest_after_static.index('(') + 2] if '(' in rest_after_static else ''
        if first_paren_context.endswith('(*'):
            return False  # function pointer variable
        return True
    if pos_eq >= 0 and pos_paren < pos_eq:
        rest_after_static = stripped[stripped.index('static') + 6:].strip()
        first_paren_context = rest_after_static[:rest_after_static.index('(') + 2] if '(' in rest_after_static else ''
        if first_paren_context.endswith('(*'):
            return False
        return True

    return False


def is_function_decl(line):
    """Heuristically detect if a static line is a function declaration/definition."""
    if FUNC_PAREN_RE.match(line):
        return _has_paren_before_semi_or_eq(line)
    return False


# Vim C style puts the return type on its own line before the function name:
#     static void
# function_name(args)
#
# These are lines like "    static void\n" or "    static char_u *\n"
# with NO variable name, no '=', no ';', no '(' on the line.
# Heuristic: if after 'static' and optional qualifiers, the line ends with
# just a type (possibly with *), and has no '=', ';', '(', '[', or ',',
# then it's a return type line for a function definition.
FUNC_RETTYPE_RE = re.compile(
    r'^\s*static\s+'
    r'(?:__thread\s+)?'              # optional __thread (already applied)
    r'(?:unsigned\s+|signed\s+)?'    # optional sign qualifier
    r'(?:volatile\s+)?'              # optional volatile
    r'(?:struct\s+|enum\s+)?'        # optional struct/enum
    r'\w+'                           # type name
    r'(?:\s*\*)*'                    # optional pointer stars
    r'\s*$'                          # end of line — no variable name!
)


def is_func_return_type_line(line):
    """Detect Vim-style function declarations where return type is on its own line."""
    stripped = line.rstrip()
    if not FUNC_RETTYPE_RE.match(stripped):
        return False
    # Extra safety: must not contain =, ;, (, [, or ,
    after_static = stripped.split('static', 1)[1].strip()
    for ch in '=;([,':
        if ch in after_static:
            return False
    return True


# ---------------------------------------------------------------------------
# Exclusion list handling
# ---------------------------------------------------------------------------

def load_exclusions(path):
    """Load exclusion patterns from file. Returns (file_excludes, var_patterns)."""
    file_excludes = set()
    var_patterns = []

    if not os.path.exists(path):
        return file_excludes, var_patterns

    with open(path) as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('file:'):
                file_excludes.add(line[5:].strip())
            elif line.startswith('pattern:'):
                var_patterns.append(re.compile(line[8:].strip()))
            else:
                # Treat as variable name glob
                var_patterns.append(re.compile(
                    r'\b' + re.escape(line).replace(r'\*', r'\w*') + r'\b'
                ))

    return file_excludes, var_patterns


def is_excluded(line, var_patterns):
    """Check if line matches any exclusion pattern."""
    for pat in var_patterns:
        if pat.search(line):
            return True
    return False


# ---------------------------------------------------------------------------
# Core transformation
# ---------------------------------------------------------------------------

def transform_line(line, var_patterns):
    """
    If line is a static variable declaration needing __thread, return
    the transformed line.  Otherwise return None (no change).
    """
    if not STATIC_RE.search(line):
        return None

    if is_function_decl(line):
        return None

    if is_func_return_type_line(line):
        return None

    # Vim signal handler declarations use SIGPROTOARG macro
    if 'SIGPROTOARG' in line:
        return None

    if is_excluded(line, var_patterns):
        return None

    # Add __thread after 'static'
    new_line = re.sub(r'^(\s*)(static)\s+', r'\1\2 __thread ', line)
    if new_line == line:
        return None
    return new_line


def process_file(filepath, var_patterns, mode='check'):
    """
    Process a single file.  Returns (changed_count, diff_text, warnings).
    mode: 'check' = dry-run count, 'diff' = return diff, 'apply' = write file
    """
    with open(filepath) as f:
        original_lines = f.readlines()

    new_lines = []
    changed = 0
    warnings = []

    for i, line in enumerate(original_lines):
        result = transform_line(line, var_patterns)
        if result is not None:
            new_lines.append(result)
            changed += 1

            # Warn about non-constant initializers
            # Look for = { with complex expressions (function calls, casts, etc.)
            stripped = line.strip()
            if '= {' in stripped or '= (' in stripped:
                # Check if initializer might be non-constant
                after_eq = stripped.split('=', 1)[1].strip() if '=' in stripped else ''
                # Simple constants: NULL, 0, FALSE, TRUE, NUL, numbers, strings, casts of 0
                if after_eq and not re.match(
                    r'^\{?\s*('
                    r'NULL|0|FALSE|TRUE|NUL|'
                    r'-?\d+|'
                    r'0x[0-9a-fA-F]+|'
                    r'\(hlf_T\)\d+|'
                    r'\(char_u\s*\*\)\s*NULL|'
                    r'"[^"]*"|'
                    r"'[^']*'|"
                    r'[\s,{}0-9NULFALSETRUExXa-fA-F\-]*'
                    r')\s*[};]?\s*$',
                    after_eq
                ):
                    warnings.append(
                        f"  {filepath}:{i+1}: possible non-constant initializer: "
                        f"{stripped[:80]}"
                    )
        else:
            new_lines.append(line)

    diff_text = ''
    if mode == 'diff' and changed > 0:
        diff_text = ''.join(difflib.unified_diff(
            original_lines, new_lines,
            fromfile=f'a/{filepath}',
            tofile=f'b/{filepath}',
            lineterm='\n'
        ))

    if mode == 'apply' and changed > 0:
        with open(filepath, 'w') as f:
            f.writelines(new_lines)

    return changed, diff_text, warnings


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Add __thread to static variable declarations for iOS TLS.'
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check', action='store_true',
                       help='Dry-run: report files and counts')
    group.add_argument('--diff', action='store_true',
                       help='Show unified diff of changes')
    group.add_argument('--apply', action='store_true',
                       help='Modify files in place')

    parser.add_argument('--exclude', default=None,
                        help='Path to exclusion list (default: tools/tls_exclude.txt)')
    parser.add_argument('files', nargs='+', help='Files to process')

    args = parser.parse_args()

    # Find exclusion list
    exclude_path = args.exclude
    if exclude_path is None:
        # Look relative to script location
        script_dir = os.path.dirname(os.path.abspath(__file__))
        exclude_path = os.path.join(script_dir, 'tls_exclude.txt')

    file_excludes, var_patterns = load_exclusions(exclude_path)

    if args.check:
        mode = 'check'
    elif args.diff:
        mode = 'diff'
    else:
        mode = 'apply'

    total_changed = 0
    total_files = 0
    all_warnings = []

    for filepath in args.files:
        basename = os.path.basename(filepath)
        if basename in file_excludes:
            continue
        if not os.path.isfile(filepath):
            continue

        changed, diff_text, warnings = process_file(filepath, var_patterns, mode)
        all_warnings.extend(warnings)

        if changed > 0:
            total_files += 1
            total_changed += changed
            if mode == 'check':
                print(f"  {filepath}: {changed} static vars need __thread")
            elif mode == 'diff':
                print(diff_text)
            elif mode == 'apply':
                print(f"  {filepath}: added __thread to {changed} declarations")

    # Summary
    if mode == 'check':
        if total_changed == 0:
            print("All static variables already have __thread markers.")
        else:
            print(f"\nTotal: {total_changed} declarations in {total_files} files need __thread")
    elif mode == 'apply':
        if total_changed == 0:
            print("No changes needed.")
        else:
            print(f"\nApplied __thread to {total_changed} declarations in {total_files} files")

    if all_warnings:
        print(f"\nWarnings ({len(all_warnings)} potential non-constant initializers):")
        for w in all_warnings:
            print(w)

    return 0 if total_changed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
