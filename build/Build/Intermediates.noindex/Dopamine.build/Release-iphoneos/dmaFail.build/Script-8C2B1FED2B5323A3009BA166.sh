#!/bin/sh
install_name_tool -change "@loader_path/libjailbreak.dylib" "@executable_path/libjailbreak.dylib" "$BUILT_PRODUCTS_DIR/$EXECUTABLE_PATH"

