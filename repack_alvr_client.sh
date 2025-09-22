#!/bin/bash
set -e
BUILDDIR="ALVR/target/aarch64-apple-ios/distribution"
HEADERPATH="ALVR/build/alvr_client_core.h"
target_framework="ALVRClientCore.framework"
target_lib="ALVRClientCore.framework/ALVRClientCore"
rm -rf alvrrepack ALVRClientCore.xcframework || true
for plat in ios maccatalyst xros xrsimulator
do
	mkdir -p alvrrepack/$plat/$target_framework/Headers
	cp tools/framework_template/$plat/Info.plist alvrrepack/$plat/$target_framework
	cp "$HEADERPATH" alvrrepack/$plat/$target_framework/Headers
done
cp "$BUILDDIR/libalvr_client_core.dylib" alvrrepack/ios/$target_lib

install_name_tool -id "@rpath/$target_lib" alvrrepack/ios/$target_lib

xcrun vtool -arch arm64 -set-build-version maccatalyst 17.0 17.0 -replace -output alvrrepack/maccatalyst/$target_lib alvrrepack/ios/$target_lib
xcrun vtool -arch arm64 -set-build-version visionos 1.0 1.0 -replace -output alvrrepack/xros/$target_lib alvrrepack/ios/$target_lib
xcrun vtool -arch arm64 -set-build-version visionossim 1.0 1.0 -replace -output alvrrepack/xrsimulator/$target_lib alvrrepack/ios/$target_lib

rm -rf ALVRClientCore.xcframework
rm -rf ALVRClient/ALVRClientCore.xcframework

xcodebuild -create-xcframework \
	-framework alvrrepack/ios/$target_framework \
	-framework alvrrepack/maccatalyst/$target_framework \
	-framework alvrrepack/xros/$target_framework \
	-framework alvrrepack/xrsimulator/$target_framework \
	-output ALVRClient/ALVRClientCore.xcframework

rm -rf alvrrepack
