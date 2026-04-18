#!/bin/sh

set -eu

resolve_brew_lib() {
  formula="$1"
  library_name="$2"

  for prefix in /opt/homebrew/opt /usr/local/opt; do
    candidate="$prefix/$formula/lib/$library_name"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

patch_binary_reference() {
  binary_path="$1"
  old_path="$2"
  new_path="$3"

  if otool -L "$binary_path" | grep -Fq "$old_path"; then
    install_name_tool -change "$old_path" "$new_path" "$binary_path"
  fi
}

djvu_lib="$(resolve_brew_lib djvulibre libdjvulibre.21.dylib || true)"
jpeg_lib="$(resolve_brew_lib jpeg-turbo libjpeg.8.dylib || true)"

if [ -z "$djvu_lib" ] || [ -z "$jpeg_lib" ]; then
  echo "warning: Skipping djvulibre embedding because Homebrew libraries were not found."
  exit 0
fi

frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
macos_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"

mkdir -p "$frameworks_dir"

bundled_djvu="$frameworks_dir/libdjvulibre.21.dylib"
bundled_jpeg="$frameworks_dir/libjpeg.8.dylib"

cp -f "$djvu_lib" "$bundled_djvu"
cp -f "$jpeg_lib" "$bundled_jpeg"
chmod 755 "$bundled_djvu" "$bundled_jpeg"

install_name_tool -id "@rpath/libjpeg.8.dylib" "$bundled_jpeg"
install_name_tool -id "@rpath/libdjvulibre.21.dylib" "$bundled_djvu"
patch_binary_reference "$bundled_djvu" "$jpeg_lib" "@rpath/libjpeg.8.dylib"

if [ -d "$macos_dir" ]; then
  find "$macos_dir" -type f | while read -r binary; do
    if file "$binary" | grep -Fq "Mach-O"; then
      patch_binary_reference "$binary" "$djvu_lib" "@rpath/libdjvulibre.21.dylib"
      patch_binary_reference "$binary" "$jpeg_lib" "@rpath/libjpeg.8.dylib"
    fi
  done
fi

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$bundled_jpeg"
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$bundled_djvu"
fi
