#!/bin/sh
# Xcode build phase: install the CPython standard library into the app bundle and turn
# each extension module into a framework (App Store rule: all binaries in Frameworks/).
# Reuses the official helpers from Python.xcframework/build/utils.sh, but excludes parts
# of the stdlib that are useless on iOS and make the app ~200 MB larger (test suite,
# IDLE, Tk, ensurepip, test extension modules).
set -e
XCF=ThirdParty/Python.xcframework
if [ ! -d "$PROJECT_DIR/$XCF" ]; then
    echo "error: $XCF missing — run: sh scripts/fetch_python.sh" >&2
    exit 1
fi
. "$PROJECT_DIR/$XCF/build/utils.sh"

EXCLUDES="--exclude libpython*.dylib --exclude test/ --exclude idlelib/ --exclude tkinter/ --exclude turtledemo/ \
 --exclude ensurepip/ --exclude __pycache__/ --exclude turtle.py --exclude _test*.so --exclude _xxtestfuzz*.so \
 --exclude _ctypes_test*.so --exclude xxlimited*.so --exclude xxsubtype*.so --exclude _remote_debugging*.so \
 --exclude config-*/ --exclude pkgconfig/"

# Override of the official install_stdlib with the exclusions above.
install_stdlib() {
    PYTHON_XCFRAMEWORK_PATH=$1
    mkdir -p "$CODESIGNING_FOLDER_PATH/python/lib"
    if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
        if [ -d "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/ios-arm64-simulator" ]; then SLICE_FOLDER="ios-arm64-simulator"; else SLICE_FOLDER="ios-arm64_x86_64-simulator"; fi
    else
        SLICE_FOLDER="ios-arm64"
    fi
    # shellcheck disable=SC2086
    rsync -au --delete $EXCLUDES "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/lib/" "$CODESIGNING_FOLDER_PATH/python/lib/"
    # shellcheck disable=SC2086
    rsync -au $EXCLUDES "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/$SLICE_FOLDER/lib-$ARCHS/" "$CODESIGNING_FOLDER_PATH/python/lib/"
}

install_python "$XCF"
echo "Python stdlib: $(du -sh "$CODESIGNING_FOLDER_PATH/python" | cut -f1)"
