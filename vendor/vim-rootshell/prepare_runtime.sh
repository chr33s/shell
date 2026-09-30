#!/bin/bash
# prepare_runtime.sh - Create VimRuntime.bundle for iOS vim
# Usage: ./prepare_runtime.sh [output_dir]
#
# Creates a ~2.4MB bundle with essential syntax highlighting support
# for common programming languages.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SRC="$SCRIPT_DIR/runtime"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
BUNDLE_NAME="VimRuntime.bundle"
BUNDLE_PATH="$OUTPUT_DIR/$BUNDLE_NAME"
RESOURCES_PATH="$BUNDLE_PATH/Contents/Resources/vim"

echo "Creating VimRuntime.bundle..."
echo "  Source: $RUNTIME_SRC"
echo "  Output: $BUNDLE_PATH"

# Clean previous build
rm -rf "$BUNDLE_PATH"

# Create bundle structure
mkdir -p "$RESOURCES_PATH"
mkdir -p "$BUNDLE_PATH/Contents"

# Create Info.plist
cat > "$BUNDLE_PATH/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.vim.runtime</string>
    <key>CFBundleName</key>
    <string>VimRuntime</string>
    <key>CFBundleVersion</key>
    <string>9.1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
EOF

# Copy root vim files (essential for vim startup)
echo "Copying root configuration files..."
ROOT_FILES=(
    "filetype.vim"
    "scripts.vim"
    "ftplugin.vim"
    "indent.vim"
    "defaults.vim"
    "ftoff.vim"
    "indoff.vim"
    "optwin.vim"
    "synmenu.vim"
)
for file in "${ROOT_FILES[@]}"; do
    if [ -f "$RUNTIME_SRC/$file" ]; then
        cp "$RUNTIME_SRC/$file" "$RESOURCES_PATH/"
    fi
done

# Create directories
mkdir -p "$RESOURCES_PATH/autoload/dist"
mkdir -p "$RESOURCES_PATH/colors"
mkdir -p "$RESOURCES_PATH/syntax"
mkdir -p "$RESOURCES_PATH/ftplugin"
mkdir -p "$RESOURCES_PATH/indent"
mkdir -p "$RESOURCES_PATH/plugin"
mkdir -p "$RESOURCES_PATH/pack/dist/opt/matchit/plugin"
mkdir -p "$RESOURCES_PATH/pack/dist/opt/matchit/autoload"
mkdir -p "$RESOURCES_PATH/pack/dist/opt/netrw/plugin"
mkdir -p "$RESOURCES_PATH/pack/dist/opt/netrw/autoload/netrw"
mkdir -p "$RESOURCES_PATH/pack/dist/opt/netrw/syntax"
mkdir -p "$RESOURCES_PATH/doc"

# Copy autoload files (needed for filetype detection)
echo "Copying autoload files..."
if [ -f "$RUNTIME_SRC/autoload/dist/ft.vim" ]; then
    cp "$RUNTIME_SRC/autoload/dist/ft.vim" "$RESOURCES_PATH/autoload/dist/"
fi
if [ -f "$RUNTIME_SRC/autoload/dist/script.vim" ]; then
    cp "$RUNTIME_SRC/autoload/dist/script.vim" "$RESOURCES_PATH/autoload/dist/"
fi

# Copy autoload files required by bundled ftplugins (omnifunc completions, etc.)
AUTOLOAD_FILES=(
    "htmlcomplete.vim"     # html.vim, markdown.vim (via html.vim)
    "htmlfold.vim"         # html.vim fold support
    "csscomplete.vim"      # css.vim
    "xmlcomplete.vim"      # xml.vim
    "xmlformat.vim"        # xml.vim
    "javascriptcomplete.vim" # javascript.vim
    "pythoncomplete.vim"   # python.vim fallback
    "python3complete.vim"  # python.vim
    "ccomplete.vim"        # c.vim, cpp.vim
    "rubycomplete.vim"     # ruby.vim
    "phpcomplete.vim"      # php.vim
    "sqlcomplete.vim"      # sql.vim
    "vimcomplete.vim"      # vim.vim
    "javaformat.vim"       # java.vim
    "spotbugs.vim"         # java.vim
)
for file in "${AUTOLOAD_FILES[@]}"; do
    if [ -f "$RUNTIME_SRC/autoload/$file" ]; then
        cp "$RUNTIME_SRC/autoload/$file" "$RESOURCES_PATH/autoload/"
    fi
done

# Copy all colorschemes (small, ~72KB total)
echo "Copying colorschemes..."
if [ -d "$RUNTIME_SRC/colors" ]; then
    cp "$RUNTIME_SRC/colors/"*.vim "$RESOURCES_PATH/colors/" 2>/dev/null || true
fi

# Copy color name lists (needed for termguicolors color name resolution)
mkdir -p "$RESOURCES_PATH/colors/lists"
if [ -d "$RUNTIME_SRC/colors/lists" ]; then
    cp "$RUNTIME_SRC/colors/lists/"*.vim "$RESOURCES_PATH/colors/lists/" 2>/dev/null || true
fi

# Syntax files - Infrastructure (required for syntax to work)
SYNTAX_INFRA=(
    "synload.vim"
    "syncolor.vim"
    "syntax.vim"
    "nosyntax.vim"
    "manual.vim"
    # Dependencies for included syntax scripts
    "autodoc.vim"
    "dtd.vim"
    "pod.vim"
    "python2.vim"
    "scheme.vim"
    "tcl.vim"
)

# Syntax files - Primary languages
SYNTAX_PRIMARY=(
    "c.vim"
    "cpp.vim"
    "python.vim"
    "javascript.vim"
    "typescript.vim"
    "go.vim"
    "rust.vim"
    "sh.vim"
    "bash.vim"
    "zsh.vim"
    "html.vim"
    "css.vim"
    "json.vim"
    "yaml.vim"
    "markdown.vim"
    "sql.vim"
    "swift.vim"
)

# Syntax files - Secondary languages
SYNTAX_SECONDARY=(
    "objc.vim"
    "objcpp.vim"
    "java.vim"
    "lua.vim"
    "xml.vim"
    "vim.vim"
    "help.vim"
    "diff.vim"
    "git.vim"
    "gitcommit.vim"
    "gitrebase.vim"
    "gitconfig.vim"
    "make.vim"
    "cmake.vim"
    "dockerfile.vim"
    "conf.vim"
    "vb.vim"
    "javascriptreact.vim"
    "typescriptreact.vim"
    "toml.vim"
    "ruby.vim"
    "php.vim"
    "perl.vim"
    "kotlin.vim"
    "scala.vim"
)

echo "Copying syntax files..."
for file in "${SYNTAX_INFRA[@]}" "${SYNTAX_PRIMARY[@]}" "${SYNTAX_SECONDARY[@]}"; do
    if [ -f "$RUNTIME_SRC/syntax/$file" ]; then
        cp "$RUNTIME_SRC/syntax/$file" "$RESOURCES_PATH/syntax/"
    fi
done

# Ftplugin files
FTPLUGIN_FILES=(
    "c.vim"
    "cpp.vim"
    "python.vim"
    "javascript.vim"
    "typescript.vim"
    "go.vim"
    "rust.vim"
    "sh.vim"
    "bash.vim"
    "zsh.vim"
    "html.vim"
    "css.vim"
    "json.vim"
    "yaml.vim"
    "markdown.vim"
    "sql.vim"
    "swift.vim"
    "vim.vim"
    "git.vim"
    "gitcommit.vim"
    "make.vim"
    "cmake.vim"
    "xml.vim"
    "lua.vim"
    "dockerfile.vim"
    "java.vim"
    "ruby.vim"
    "php.vim"
    "perl.vim"
)

echo "Copying ftplugin files..."
for file in "${FTPLUGIN_FILES[@]}"; do
    if [ -f "$RUNTIME_SRC/ftplugin/$file" ]; then
        cp "$RUNTIME_SRC/ftplugin/$file" "$RESOURCES_PATH/ftplugin/"
    fi
done

# Indent files
INDENT_FILES=(
    "c.vim"
    "cpp.vim"
    "python.vim"
    "javascript.vim"
    "typescript.vim"
    "go.vim"
    "rust.vim"
    "sh.vim"
    "bash.vim"
    "zsh.vim"
    "html.vim"
    "css.vim"
    "json.vim"
    "yaml.vim"
    "sql.vim"
    "swift.vim"
    "vim.vim"
    "make.vim"
    "cmake.vim"
    "xml.vim"
    "lua.vim"
    "java.vim"
    "ruby.vim"
    "php.vim"
    "perl.vim"
)

echo "Copying indent files..."
for file in "${INDENT_FILES[@]}"; do
    if [ -f "$RUNTIME_SRC/indent/$file" ]; then
        cp "$RUNTIME_SRC/indent/$file" "$RESOURCES_PATH/indent/"
    fi
done

# Copy essential plugins
echo "Copying plugins..."
PLUGIN_FILES=(
    "matchparen.vim"
    "netrwPlugin.vim"
)
for file in "${PLUGIN_FILES[@]}"; do
    if [ -f "$RUNTIME_SRC/plugin/$file" ]; then
        cp "$RUNTIME_SRC/plugin/$file" "$RESOURCES_PATH/plugin/"
    fi
done

# Copy matchit pack
echo "Copying matchit plugin..."
if [ -f "$RUNTIME_SRC/pack/dist/opt/matchit/plugin/matchit.vim" ]; then
    cp "$RUNTIME_SRC/pack/dist/opt/matchit/plugin/matchit.vim" "$RESOURCES_PATH/pack/dist/opt/matchit/plugin/"
fi
if [ -f "$RUNTIME_SRC/pack/dist/opt/matchit/autoload/matchit.vim" ]; then
    cp "$RUNTIME_SRC/pack/dist/opt/matchit/autoload/matchit.vim" "$RESOURCES_PATH/pack/dist/opt/matchit/autoload/"
fi

# Copy netrw pack (file browser - moved to pack in Vim 9.1)
echo "Copying netrw plugin..."
if [ -f "$RUNTIME_SRC/pack/dist/opt/netrw/plugin/netrwPlugin.vim" ]; then
    cp "$RUNTIME_SRC/pack/dist/opt/netrw/plugin/netrwPlugin.vim" "$RESOURCES_PATH/pack/dist/opt/netrw/plugin/"
fi
for file in netrw.vim netrw_gitignore.vim; do
    if [ -f "$RUNTIME_SRC/pack/dist/opt/netrw/autoload/$file" ]; then
        cp "$RUNTIME_SRC/pack/dist/opt/netrw/autoload/$file" "$RESOURCES_PATH/pack/dist/opt/netrw/autoload/"
    fi
done
# Netrw subdirectory autoload files
for file in fs.vim msg.vim os.vim; do
    if [ -f "$RUNTIME_SRC/pack/dist/opt/netrw/autoload/netrw/$file" ]; then
        cp "$RUNTIME_SRC/pack/dist/opt/netrw/autoload/netrw/$file" "$RESOURCES_PATH/pack/dist/opt/netrw/autoload/netrw/"
    fi
done
if [ -f "$RUNTIME_SRC/pack/dist/opt/netrw/syntax/netrw.vim" ]; then
    cp "$RUNTIME_SRC/pack/dist/opt/netrw/syntax/netrw.vim" "$RESOURCES_PATH/pack/dist/opt/netrw/syntax/"
fi

# Copy all documentation (help files + tags)
echo "Copying documentation..."
if [ -d "$RUNTIME_SRC/doc" ]; then
    cp "$RUNTIME_SRC/doc/"*.txt "$RESOURCES_PATH/doc/" 2>/dev/null || true
    cp "$RUNTIME_SRC/doc/tags" "$RESOURCES_PATH/doc/" 2>/dev/null || true
fi

# Calculate and display size
BUNDLE_SIZE=$(du -sh "$BUNDLE_PATH" | cut -f1)
echo ""
echo "=== VimRuntime.bundle created ==="
echo "Location: $BUNDLE_PATH"
echo "Size: $BUNDLE_SIZE"
echo ""
echo "File counts:"
echo "  Root files: $(ls -1 "$RESOURCES_PATH/"*.vim 2>/dev/null | wc -l | tr -d ' ')"
echo "  Syntax files: $(ls -1 "$RESOURCES_PATH/syntax/" 2>/dev/null | wc -l | tr -d ' ')"
echo "  Colorschemes: $(ls -1 "$RESOURCES_PATH/colors/" 2>/dev/null | wc -l | tr -d ' ')"
echo "  Ftplugin files: $(ls -1 "$RESOURCES_PATH/ftplugin/" 2>/dev/null | wc -l | tr -d ' ')"
echo "  Indent files: $(ls -1 "$RESOURCES_PATH/indent/" 2>/dev/null | wc -l | tr -d ' ')"
echo "  Doc files: $(ls -1 "$RESOURCES_PATH/doc/" 2>/dev/null | wc -l | tr -d ' ')"
echo ""
echo "To use in your iOS app:"
echo "  1. Add VimRuntime.bundle to your Xcode project"
echo "  2. Before launching vim, set VIMRUNTIME:"
echo ""
echo '     if let bundlePath = Bundle.main.path(forResource: "VimRuntime", ofType: "bundle") {'
echo '         setenv("VIMRUNTIME", "\(bundlePath)/Contents/Resources/vim", 1)'
echo '     }'
