#!/bin/bash

echo "Building Numaric..."

swift build -c release

if [ $? -eq 0 ]; then
    echo "Build successful!"
    
    APP_NAME="Numaric.app"
    BUILD_DIR=".build/release"
    APP_PATH="$BUILD_DIR/$APP_NAME"
    
    rm -rf "$APP_PATH"
    mkdir -p "$APP_PATH/Contents/MacOS"
    mkdir -p "$APP_PATH/Contents/Resources"
    
    cp Info.plist "$APP_PATH/Contents/"
    cp "$BUILD_DIR/Numaric" "$APP_PATH/Contents/MacOS/"
    
    echo "App bundle created at: $APP_PATH"
    echo "You can now run the app or move it to /Applications"
else
    echo "Build failed!"
    exit 1
fi
